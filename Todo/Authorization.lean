/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Authentication.Instances
public import AuthenticationOAuth
public import AuthenticationPostgres
public import Postgres
public import MCP
public import Middleware
public import Todo.Links
public import Todo.Tenant

public section

open Authentication
open Routes
open Std Http

namespace Todo.Authorization

/-! ## What a token may do

Two scopes, because the person granting one has two answers worth distinguishing: an agent that
reads the list and an agent that changes it. Which tools each admits is `Todo.Mcp`'s to say; what
is here is the pair of names, since the authorization server has to advertise them and the
consent page has to describe them. -/

def read : OAuth.Scope := ⟨"todos:read"⟩
def write : OAuth.Scope := ⟨"todos:write"⟩

def scopes : List OAuth.Scope := [read, write]

/-- What to call a scope on the consent page. A person deciding whether to grant one is owed
something better than the string a protocol uses. -/
def describe (scope : OAuth.Scope) : String :=
  if scope == read then "See your todos"
  else if scope == write then "Add, change and delete your todos"
  else scope.value

/-! ## Where this server is

The endpoints sit at the origin rather than below the tenant's path, which `OAuthConfig.standard`
would have given them. There is one tenant and the application is mounted at the root, so the
prefix would distinguish nothing, and it puts the metadata document at the place every client
looks first: RFC 8414 §3 inserts the well-known suffix ahead of an issuer's path, so an issuer
with a path is discovered at a URL clients reach only by building it. -/

def origin (base : BaseUrl) : String := BaseUrl.trimTrailingSlashes base.origin

/-- What a token is for, and the only audience one is accepted at. A token issued for anywhere
else is refused here however valid it is, which is the check the MCP specification is most
emphatic about. -/
def resource (base : BaseUrl) : OAuth.ResourceIndicator := ⟨origin base ++ links.mcp⟩

def config (base : BaseUrl) : OAuth.OAuthConfig Todo.tenant where
  issuer := origin base
  authorizationEndpoint := origin base ++ links.oauthAuthorize
  tokenEndpoint := origin base ++ links.oauthToken
  registrationEndpoint := origin base ++ links.oauthRegister
  scopesSupported := scopes

/-- No adapter fetches a client's metadata document, so `client_id_metadata_document_supported`
comes out `false` and a client registers dynamically instead. Both are ways in and clients
implement both; this is the one that needs no outbound HTTP, which the deployed function has no
route for at all.

Withdrawing the offer is what leaves a way in rather than two. A client believes the document
ahead of a refusal, so advertising a mechanism that ends in one does not leave it a choice. -/
def documents : Option (OAuth.ClientDocuments IO) := none

def metadata (base : BaseUrl) : Json := OAuth.metadataDocument documents (config base)

/-- Where a client is told to look for the authorization server, which is what a refusal from
the MCP endpoint carries so that an agent holding no token can find its way to one. -/
def metadataUrl (base : BaseUrl) : String := origin base ++ links.mcpMetadata

/-- The protected resource metadata document of RFC 9728, which the authorisation server library
deliberately does not serve: it describes this resource, not that server.

`authorization_servers` names ours and only ours. A client that finds several is entitled to pick
one, and there is nothing to be gained here by offering a choice. -/
def resourceMetadata (base : BaseUrl) : Json :=
  MCP.ProtectedResourceMetadata.toJson
    { resource := (resource base).value
      authorizationServers := #[(config base).issuer]
      scopesSupported := (scopes.map (·.value)).toArray }

/-! ## What a handler deals in

The names the routes use, so that they say what they mean about this application rather than
naming a library twice over on every line. Each is the library's own type; the tenant is settled
here because there is only one and a handler has nothing to say about it. -/

abbrev Params := OAuth.Params
abbrev Scope := OAuth.Scope
abbrev Outcome := OAuth.Service.Outcome Todo.tenant
abbrev Prompt := OAuth.Service.ConsentPrompt Todo.tenant
abbrev Decision := OAuth.Service.ConsentDecision Todo.tenant
abbrev Tokens := OAuth.Service.TokenResponse
abbrev Refusal := OAuth.ErrorResponse
abbrev Rejection := OAuth.AccessToken.Rejection
abbrev Claims := OAuth.Service.TokenClaims Todo.tenant

/-- Everything a refusal at the MCP endpoint answers with. -/
structure Challenge where
  status : Nat
  /-- The `WWW-Authenticate` value RFC 6750 §3 asks for. -/
  header : String
  /-- The same refusal as a document, because a header is not always what arrives. A Lambda
  function URL renames `WWW-Authenticate`, and there is no setting that stops it, so a deployment
  can be correct and still refuse without saying why. The body is ours all the way to the client.
  -/
  document : Json

/-- How a rejection reads to whoever is refused: the code RFC 6750 §3.1 gives it, and a sentence
about this server rather than about the protocol. -/
private def reasonFor : Rejection → String × String
  | .unknown => ("invalid_token", "this server did not issue that token, or no longer knows it")
  | .expired => ("invalid_token", "the token has expired; refresh it or ask again")
  | .revoked => ("invalid_token", "the token was revoked; ask again")
  | .wrongAudience => ("invalid_token", "the token was issued for a different resource")
  | .insufficientScope _ =>
    ("insufficient_scope", "the token was not granted the scopes this endpoint needs")

/-- The document carries `resource_metadata` for the same reason the header does: it is how an
agent holding nothing gets from a refusal to a token, and it is the part that a renamed header
loses. `scope` names everything needed at once, so a client comes back for all of it rather than
once per scope. -/
def challengeFor (base : BaseUrl) (rejection : Rejection) : Challenge :=
  let (error, description) := reasonFor rejection
  { status := OAuth.Service.rejectionStatus rejection
    header := OAuth.Service.challenge rejection (some (metadataUrl base))
    document := Json.mkObj
      ([ ("error", .str error),
         ("error_description", .str description),
         ("resource_metadata", .str (metadataUrl base)) ]
        ++ match rejection with
           | .insufficientScope needed => [("scope", .str (OAuth.Scope.render needed))]
           | _ => []) }

/-! ## Wiring -/

def ports (pool : _root_.Postgres.Pool) (peppers : PepperRing) : OAuth.Service.Ports IO :=
  let conn := Authentication.Postgres.poolConnection pool
  { store := Sql.sqlAuthStore Authentication.Postgres.dialect conn
    oauth := OAuth.sqlOAuthStore Authentication.Postgres.dialect conn
    documents
    peppers }

/-- Everything the routes need, as operations rather than as the ports they are reached through.
Same reason `Todo.Store` and `Todo.Auth.Identity` are records: the handlers can then be driven
without a database, and what happens against a real one is settled where it happens. -/
structure Site where
  /-- The address an agent is pointed at, which is the one thing somebody setting one up has to
  be told. -/
  endpoint : String
  /-- The RFC 8414 document, which is how a client learns the endpoints exist at all. -/
  metadata : Json
  /-- The RFC 9728 document, which is how a client learns which server issues tokens for here. -/
  resourceMetadata : Json
  authorize : Params → Option String → IO Outcome
  conclude : Decision → IO Outcome
  token : Params → IO (Except Refusal Tokens)
  /-- The status and body a registration is answered with, either way, since the only thing a
  caller does with either outcome is render it. -/
  register : Json → IO (Nat × Json)
  /-- Whether a presented token may act here, and as whom. -/
  verify : String → IO (Except Rejection Claims)
  /-- Withdraws every connection this account holds here, and reports how many there were. -/
  disconnect : Todo.Account → IO Nat
  /-- What a refusal at the MCP endpoint answers with, which is `challengeFor` at whatever this
  server's own address is. -/
  challenge : Rejection → Challenge

/-- Everything that is settled by the address alone, so that anything
standing in for the operations still answers these the way a deployment would. -/
def describing (base : BaseUrl) : Site :=
  { endpoint := (Authorization.resource base).value
    metadata := Authorization.metadata base
    resourceMetadata := Authorization.resourceMetadata base
    challenge := challengeFor base
    authorize := fun _ _ => pure (.refuse { error := .serverError, description := "" })
    conclude := fun _ => pure (.refuse { error := .serverError, description := "" })
    token := fun _ => pure (.error { error := .serverError, description := "" })
    register := fun _ => pure (500, Json.mkObj [])
    verify := fun _ => pure (.error .unknown)
    disconnect := fun _ => pure 0 }

/-- What a client that named no scopes is asked about.

OAuth 2.1 §3.2.2.1 leaves a server two answers to a request carrying no `scope`: a default, or a
refusal. The library supplies the refusal and leaves the default here, because what is on offer
is this deployment's to say. Agents that name no scopes are common rather than odd, so without a
default they would all be turned away.

Amending the prompt rather than the request it came from is the difference between offering a
default and pretending one was asked for. `ConsentPrompt.answered` carries the amendment into the
code, so what is issued matches what the page displayed, while `prompt.request` still records
what the client actually sent.

The default is everything on offer, which is not the same as granting it: the page still asks,
and a box unticked there is a scope withheld. -/
def withDefaultScopes (prompt : Prompt) : Prompt :=
  if prompt.requestedScopes.isEmpty then { prompt with requestedScopes := scopes } else prompt

def site (ports : OAuth.Service.Ports IO) (base : BaseUrl) : Site :=
  let config := Authorization.config base
  { describing base with
    -- Amended here rather than in the handler so that both the page and the answer to it see the
    -- same prompt: the handler runs `authorize` again on the way through, which is what re-reads
    -- the request rather than reassembling it from hidden fields.
    authorize := fun params session => do
      match ← OAuth.Service.authorize ports config params (session.map (⟨·⟩)) with
      | .consent prompt => pure (.consent (withDefaultScopes prompt))
      | settled => pure settled
    conclude := OAuth.Service.conclude ports config
    token := OAuth.Service.token ports config
    register := fun body => do
      match ← OAuth.Service.register (tenant := Todo.tenant) ports body with
      | .ok record => pure (OAuth.Registration.createdStatus, OAuth.Registration.response record)
      | .error refusal => pure (refusal.status, refusal.toJson)
    verify := fun presented =>
      OAuth.Service.verify ports ⟨presented⟩ (Authorization.resource base)
    disconnect := fun account => do
      let live ← OAuth.Service.connections ports account
      for connection in live do
        OAuth.Service.revoke ports account connection.client connection.resource
      pure live.length }

/-! ## Reading a request -/

/-- Every parameter as it was sent, duplicates included.

Duplicates are the point of not collapsing them into a lookup: OAuth 2.1 §4.1.1 makes a parameter
sent twice `invalid_request`, and a reader that kept the first would accept a request the
specification says to refuse, in exactly the case somebody is trying something. -/
def params (query : URI.Query) : OAuth.Params :=
  query.toArray.toList.filterMap fun (name, value) =>
    name.decode.map fun name => (name, (value.bind (·.decode)).getD "")

end Todo.Authorization
