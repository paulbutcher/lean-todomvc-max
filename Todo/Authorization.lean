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

/-- The library's document, less the one claim this deployment cannot make good on.

`client_id_metadata_document_supported` is what tells a client it may use a URL as its identifier
instead of registering. A client that takes the offer is then refused, because `noDocuments`
fetches nothing and the deployed function sits in a VPC with no route to the internet that could.
Offering it is what makes it a dead end; withdrawing it sends the same client to
`/oauth/register`, which needs nothing this deployment does not have.

The library states it unconditionally, on the reasoning that it describes the protocol rather
than a deployment. It describes both: whether a document can be fetched is exactly a property of
where the server is standing. -/
def metadata (base : BaseUrl) : Json :=
  Json.mergeObj (OAuth.metadataDocument (config base))
    (Json.mkObj [("client_id_metadata_document_supported", .bool false)])

/-- Where a client is told to look for the authorization server, which is what a refusal from
the MCP endpoint carries so that an agent holding no token can find its way to one. -/
def metadataUrl (base : BaseUrl) : String := origin base ++ links.mcpMetadata

/-- The protected resource metadata document of RFC 9728, which the authorisation server library
deliberately does not serve: it describes this resource, not that server.

`authorization_servers` names ours and only ours. A client that finds several is entitled to pick
one, and there is nothing to be gained here by offering a choice. -/
def resourceMetadata (base : BaseUrl) : Json :=
  Json.mkObj
    [ ("resource", .str (resource base).value),
      ("authorization_servers", .arr #[.str (config base).issuer]),
      ("scopes_supported", .arr (scopes.map (Json.str ·.value)).toArray),
      ("bearer_methods_supported", .arr #[.str "header"]) ]

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

/-- The status RFC 6750 gives a rejection, and the `WWW-Authenticate` value that goes with it.
The value carries the address of the protected resource metadata document, which is how an agent
holding nothing gets from a 401 to a token. -/
def challengeFor (base : BaseUrl) (rejection : Rejection) : Nat × String :=
  (OAuth.Service.rejectionStatus rejection,
   OAuth.Service.challenge rejection (some (metadataUrl base)))

/-! ## Wiring -/

/-- No adapter fetches a client's metadata document, so a `client_id` that is a URL is refused
and a client registers dynamically instead. Both are ways in and clients implement both; this is
the one that needs no outbound HTTP, which the deployed function has no route for at all.

Which is why `metadata` withdraws the offer of the other one. A client believes the document
before it believes a refusal, so leaving the offer standing does not leave two ways in: it leaves
one way in and one that ends here.

Refusing rather than omitting the port because the port has no default: what a deployment without
a fetcher does is exactly this, and saying it here is what makes it visible. -/
def noDocuments : OAuth.ClientDocuments IO where
  fetch _ := pure (.error "this server does not fetch client metadata documents")

def ports (pool : _root_.Postgres.Pool) (peppers : PepperRing) : OAuth.Service.Ports IO :=
  let conn := Authentication.Postgres.poolConnection pool
  { store := Sql.sqlAuthStore Authentication.Postgres.dialect conn
    oauth := OAuth.sqlOAuthStore Authentication.Postgres.dialect conn
    documents := noDocuments
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
  /-- What a refusal at the MCP endpoint answers with, which is `challengeFor` at whatever this
  server's own address is. -/
  challenge : Rejection → Nat × String

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
    verify := fun _ => pure (.error .unknown) }

/-- What a client that named no scopes is taken to have asked for.

OAuth 2.1 §3.2.2.1 leaves a server two answers to a request carrying no `scope`: a default, or a
refusal. Granting nothing is neither, and it is the one that looks like success. The client is
issued a token, the person is asked nothing because there is nothing to ask, and every tool the
token reaches is filtered away, so what arrives is a connection with no tools on it and nothing
anywhere saying why. Agents that name no scopes are the common case rather than the odd one.

The default is everything on offer, which is not the same as granting it: the consent page still
asks, and a box unticked there is a scope withheld.

A `scope` that is present and blank counts as absent. It is the same request in every way that
matters, and the difference between naming nothing and naming no scopes is not one a person
consenting could be shown. -/
def withDefaultScopes (params : Params) : Params :=
  let named := params.any fun (name, value) => name == "scope" && !value.trimAscii.isEmpty
  if named then params
  else (params.filter (·.1 != "scope"))
    ++ [("scope", String.intercalate " " (scopes.map (·.value)))]

def site (ports : OAuth.Service.Ports IO) (base : BaseUrl) : Site :=
  let config := Authorization.config base
  { describing base with
    authorize := fun params session =>
      OAuth.Service.authorize ports config (withDefaultScopes params) (session.map (⟨·⟩))
    conclude := OAuth.Service.conclude ports config
    token := OAuth.Service.token ports config
    register := fun body => do
      match ← OAuth.Service.register (tenant := Todo.tenant) ports body with
      | .ok record => pure (OAuth.Registration.createdStatus, OAuth.Registration.response record)
      | .error refusal => pure (refusal.status, refusal.toJson)
    verify := fun presented =>
      OAuth.Service.verify ports ⟨presented⟩ (Authorization.resource base) }

/-! ## Reading a request -/

/-- The credential a request presents, if it presents one in the only form MCP allows. -/
def bearer? (header : Option String) : Option String :=
  header.bind fun value =>
    let trimmed := value.trimAscii.toString
    if trimmed.toLower.startsWith "bearer " then some (trimmed.drop 7).trimAscii.toString
    else none

/-- Every parameter as it was sent, duplicates included.

Duplicates are the point of not collapsing them into a lookup: OAuth 2.1 §4.1.1 makes a parameter
sent twice `invalid_request`, and a reader that kept the first would accept a request the
specification says to refuse, in exactly the case somebody is trying something. -/
def params (query : URI.Query) : OAuth.Params :=
  query.toArray.toList.filterMap fun (name, value) =>
    name.decode.map fun name => (name, (value.bind (·.decode)).getD "")

end Todo.Authorization
