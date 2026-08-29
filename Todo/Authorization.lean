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

def config (base : BaseUrl) : OAuth.OAuthConfig Todo.tenant :=
  OAuth.OAuthConfig.atOrigin base scopes

/-- No adapter fetches a client's metadata document, so `client_id_metadata_document_supported`
comes out `false` and a client registers dynamically instead. Both are ways in and clients
implement both; this is the one that needs no outbound HTTP, which the deployed function has no
route for at all.

Withdrawing the offer is what leaves a way in rather than two. A client believes the document
ahead of a refusal, so advertising a mechanism that ends in one does not leave it a choice. -/
def documents : Option (OAuth.ClientDocuments IO) := none

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
      authorizationServers := #[origin base]
      scopesSupported := (scopes.map (·.value)).toArray }

/-! ## What a handler deals in

The names the routes use, so that they say what they mean about this application rather than
naming a library twice over on every line. Each is the library's own type; the tenant is settled
here because there is only one and a handler has nothing to say about it. -/

abbrev Scope := OAuth.Scope
abbrev Rejection := OAuth.AccessToken.Rejection
abbrev Claims := OAuth.Service.TokenClaims Todo.tenant

-- The names the consent form carries its answer under, which the routes reading it back fix.
export OAuth.ConsentForm (answerField approveValue)

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

/-- Both halves name `metadataUrl`, which is how an agent holding nothing gets from a refusal to
a token and is the part a renamed header loses. -/
def challengeFor (base : BaseUrl) (rejection : Rejection) : Challenge :=
  { status := OAuth.Service.rejectionStatus rejection
    header := OAuth.Service.challenge rejection (some (metadataUrl base))
    document := OAuth.Service.refusalDocument rejection (some (metadataUrl base)) }

/-! ## Wiring -/

def ports (pool : _root_.Postgres.Pool) (peppers : PepperRing) : OAuth.Service.Ports IO :=
  let conn := Authentication.Postgres.poolConnection pool
  { store := Sql.sqlAuthStore Authentication.Postgres.dialect conn
    oauth := OAuth.sqlOAuthStore Authentication.Postgres.dialect conn
    documents
    peppers }

/-- What this application still answers for once the authorisation server's own endpoints are
the library's: the resource it protects, whether a token may act on it, and how a person takes
an approval back. Operations rather than the ports they are reached through, for the reason
`Todo.Store` and `Todo.Auth.Identity` are records: the handlers can then be driven without a
database, and what happens against a real one is settled where it happens. -/
structure Site where
  /-- The address an agent is pointed at, which is the one thing somebody setting one up has to
  be told. -/
  endpoint : String
  /-- The RFC 9728 document, which is how a client learns which server issues tokens for here.
  Served by this application rather than by the library, because it describes this resource
  rather than that server. -/
  resourceMetadata : Json
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
    resourceMetadata := Authorization.resourceMetadata base
    challenge := challengeFor base
    verify := fun _ => pure (.error .unknown)
    disconnect := fun _ => pure 0 }

def site (ports : OAuth.Service.Ports IO) (base : BaseUrl) : Site :=
  { describing base with
    verify := fun presented =>
      OAuth.Service.verify ports ⟨presented⟩ (Authorization.resource base)
    disconnect := fun account => do
      let live ← OAuth.Service.connections ports account
      for connection in live do
        OAuth.Service.revoke ports account connection.client connection.resource
      pure live.length }

end Todo.Authorization
