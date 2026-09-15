/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Authentication.Instances
public import AuthenticationHttp
public import AuthenticationOidcHttp
public import AuthenticationPostgres
public import Postgres
public import Middleware
public import Telemetry
public import Todo.AuthMail
public import Todo.Authorization
public import Todo.AuthViews
public import Todo.Federation
public import Todo.Tenant

public section

open Authentication
open Authentication.Sql
open Std Http
open Std.Http.Server

namespace Todo.Auth

/-! ## Configuration -/

/-- What the deployment decides. Everything else about the tenant is settled below, because
there is one tenant and nothing about it varies between deployments. -/
structure Settings where
  /-- Digests every credential the library stores, so it has to outlive any one process and be
  the same for every instance sharing the database: rotating it without an overlap window signs
  everyone out and invalidates every link in flight. -/
  pepper : Pepper
  /-- Where the magic link points, which is the one thing about this application the mail has to
  know and the application cannot discover for itself. -/
  baseUrl : BaseUrl
  /-- Only the address is a deployment's to choose: the name beside it in an inbox is what
  this application is called, which is settled below and not per deployment. -/
  senderAddress : EmailAddress
  /-- Where a reply goes. `none` leaves the sending address to receive them, which for the
  no-reply address a deployment usually sends from is nowhere anybody reads. -/
  replyTo : Option EmailAddress := none
  transport : EmailTransport IO
  /-- The providers this deployment offers, and the key their secrets are sealed under. `none`
  is the deployment that offers the magic link and nothing else. -/
  federation : Option Todo.Federation.Settings := none

/-- What a refusal is allowed to say.

The library's default says nothing whatever, which is right for the outcomes that identify a
person. That an address has no account, or was not invited, is precisely what somebody asking
after other people's addresses wants to learn, and those stay indistinguishable from a link
being sent.

Throttling is not one of those. The limiter is consulted before anything that depends on the
address existing, so the identical refusal reaches an address with an account and one without and
no comparison between them separates the two. What it does disclose is that this address has been
asked after recently, which is ambiguous with the requester's own budget anyway. Set against
that: a page that silently does nothing sends whoever hit the limit looking for a broken mail
server.

A malformed address describes what was typed and nobody at all.

`throttled` also carries a failed human check and a failure to draw random bytes, so those read
as "try again later" too. Neither is reachable here: the check admits everyone and the other is
the operating system's entropy source failing. -/
@[expose] def messageFor : SignInOutcome → SignInMessage
  | .throttled => .tryAgainLater
  | .malformedAddress => .addressMalformed
  | _ => .checkYourMail

def responsePolicy : SignInResponsePolicy IO where
  respond _ outcome := pure { message := messageFor outcome, notice := none }

/-- The store and the limiter draw from the pool the application already has, rather than
authentication holding a connection of its own on top of it. -/
def ports (pool : _root_.Postgres.Pool) (settings : Settings) : Service.Ports IO :=
  let conn := Authentication.Postgres.poolConnection pool
  { store := sqlAuthStore Authentication.Postgres.dialect conn
    transport := settings.transport
    responsePolicy := responsePolicy
    limiter := rateLimiter Authentication.Postgres.dialect conn
    responseFloor := ResponseFloor.sleeping 400
    humanCheck := HumanCheck.unchecked IO
    peppers := { current := settings.pepper } }

/-- What this application is called wherever somebody sees it: the sign-in pages, the subject
line of the mail, and the name beside the address it arrives from. -/
def displayName : String := "TodoMVC"

/-- Generic in the tenant so that the lookup below can answer for the one it was asked about
rather than having to prove it is the one this application has. -/
def tenantConfig (settings : Settings) (t : TenantId) : TenantConfig t where
  displayName := Auth.displayName
  baseUrl := settings.baseUrl
  sendingIdentity :=
    { address := settings.senderAddress, displayName := Auth.displayName,
      replyTo := settings.replyTo }
  signupPolicy := .unrestricted
  templates := Todo.AuthMail.templates
  -- The application is mounted at the root, so a session cookie confined to the tenant's own
  -- path would never be offered to any route that needs it.
  sessionCookiePath := "/"
  -- `/oauth/authorize` is here because an authorization request that arrives with nobody signed
  -- in has to survive signing in: the allowlist is matched against the path alone, so the
  -- request's own parameters ride along and the person lands back on the consent page rather
  -- than on the list, with the agent still waiting.
  returnToAllowlist :=
    ["/", "/active", "/completed", Routes.links.account, Routes.links.oauthAuthorize]
  -- Empty unless a deployment named one, which is what makes the federated routes answer
  -- `not found` for every provider rather than being mounted conditionally.
  providers := (settings.federation.map (·.providers)).getD []

structure Site where
  ports : Service.Ports IO
  /-- The authorisation server reaches its own two stores through these, and the routes it now
  serves need them directly rather than through `authorization`. -/
  oauthPorts : OAuth.Service.Ports IO
  authorization : Todo.Authorization.Site
  /-- What a federated sign-in is made of, and `none` where none is offered. Held here rather
  than rebuilt per request because the discovery document and the key set are cached inside it. -/
  oidc : Option (Oidc.SignInPorts IO)
  settings : Settings

/-- The federated ports are handed in rather than built here, because they hold caches and this
is not `IO`: what a process must do once, the call site can then be seen doing once.
`Todo.Federation.ports` is what builds them. -/
def site (pool : _root_.Postgres.Pool) (settings : Settings)
    (oidc : Option (Oidc.SignInPorts IO) := none) : Site :=
  let oauthPorts := Todo.Authorization.ports pool { current := settings.pepper }
  { ports := ports pool settings
    oauthPorts
    authorization := Todo.Authorization.site oauthPorts settings.baseUrl
    oidc
    settings }

/-- Where a refused federated sign-in is written down, since every one of them renders the same
page and that page is the only other thing that happens.

A log record rather than a span attribute, and an unparented one: the port is `IO`, so neither
the request's span nor anything else is in scope to hang it under. It is found by its attributes
rather than by the trace it belongs to.

`warn` rather than `error`: a provider having a bad afternoon, a deployment whose secret will not
open, and somebody who changed their mind at the provider all arrive here, and none of them is
this process failing. Which it was is `auth.refusal`.

The tenant is not recorded. There is one, so a name that never varies separates nothing. -/
private def observeRefusal (_tenant : TenantId) (provider : ProviderId)
    (reason : Authentication.OidcHttp.Refusal) : IO Unit :=
  Telemetry.runTelemetry <| Telemetry.warn "federated sign-in refused"
    [("auth.provider", .str (Todo.Federation.label provider)),
     ("auth.refusal", .str reason.name)]

namespace Site

def config (s : Site) : TenantConfig Todo.tenant := tenantConfig s.settings Todo.tenant

/-- A tenant this application does not recognise is answered the way an unrouted path is, which
is the library's requirement and costs nothing here: there is only ever one. -/
def http (s : Site) : Authentication.Http.Config where
  ports := s.ports
  pages := Todo.pages (config s).providers
  tenant := fun t => pure (if t == Todo.tenant then some (tenantConfig s.settings t) else none)

/-- The authorisation server's own endpoints, at the origin rather than below the tenant's path:
there is one tenant and the application is mounted at the root, so the prefix would distinguish
nothing, and it puts the metadata document where every client looks first.

`defaultScopes` is set, which is the half of OAuth 2.1 §3.2.2.1 the library leaves to a
deployment. Everything on offer, because agents that name no scopes are common rather than odd
and the alternative is refusing them all; the page still asks, and a box left unticked is a scope
withheld. -/
def oauth (s : Site) : Authentication.OAuth.Http.Config where
  ports := s.oauthPorts
  pages := Todo.oauthPages
  mountedAt := .origin Todo.tenant
  defaultScopes := some Todo.Authorization.scopes
  tenant := fun t => pure (if t == Todo.tenant then some (tenantConfig s.settings t) else none)
  oauth := fun t =>
    if h : t = Todo.tenant then pure (some (h ▸ Todo.Authorization.config s.settings.baseUrl))
    else pure none

/-- The federated sign-in routes, empty where no provider is configured. The library refuses a
provider the tenant does not name, so mounting them regardless would answer the same way; this
keeps a deployment that offers none from carrying routes for them at all. -/
def federatedRoutes (s : Site) : List (Routing.Route Routing.Result) :=
  match s.oidc with
  | none => []
  | some oidc =>
    Authentication.OidcHttp.routes
      { ports := s.ports
        oidc
        tenant := fun t => pure (if t == Todo.tenant then some (tenantConfig s.settings t) else none)
        refusedPage := Todo.federationRefusedPage
        observeRefusal
        notFoundPage := Todo.notFoundPage }

end Site

/-! ## Reading the session -/

def sessionCookie : String := "auth_session"

private def presented (req : Request Body.Stream) : Option CredentialValue :=
  ((req.extensions.get Middleware.Cookies).bind (·.get sessionCookie)).map (⟨·⟩)

/-- Who the request is, or nobody.

Three of the four reasons a cookie names nobody are a session reaching the end of its life, and
the fourth is a cookie from another database; each arrives on every request a signed-out browser
makes, so recording them here would cost a line per request to say somebody is signed out. The
one place the difference decides anything is a link start, which the library observes itself. -/
private def identify (s : Site) (req : Request Body.Stream) : IO (Option Todo.Account) := do
  match presented req with
  | none => pure none
  | some credential =>
    pure ((← Service.identify s.ports s.config credential).toOption.map (·.account))

/-- The address the account signs in with, which is the only thing about it worth showing. -/
private def addressOf (s : Site) (account : Todo.Account) : IO (Option String) := do
  pure ((← s.ports.store.accountById Todo.tenant account).map (·.primaryEmail.render))

/-- Ends the session the request arrived on, and only that one: signing out of a browser is not a
statement about any other browser the account is signed in on. -/
private def signOut (s : Site) (req : Request Body.Stream) (account : Todo.Account) : IO Unit := do
  let live ← Service.sessions s.ports account (presented := presented req)
  for session in live do
    if session.current then
      discard <| Service.revokeSession s.ports account session.id

/-- Every way into this account other than its address, which is what the account page shows and
what `unlink` takes one of away from. -/
private def linked (s : Site) (account : Todo.Account) : IO (List (Credential Todo.tenant)) :=
  Service.linkedIdentities s.ports account

/-- Refusing to remove the last way in is the library's, not this application's: an account whose
address can no longer be mailed and whose only provider has gone is one nobody can reach. -/
private def unlink (s : Site) (account : Todo.Account) (credential : CredentialId Todo.tenant) :
    IO (Except Service.UnlinkRefusal Unit) :=
  Service.unlinkIdentity s.ports account credential

/-- What the application needs of a signed-in person, as operations rather than as the `Site`
they are reached through. Same reason `Todo.Store` is a record: the handlers can then be driven
without a database, and what happens against a real one is settled where it happens.

Each is `IO` because that is what the library ports are. -/
structure Identity where
  of : Request Body.Stream → IO (Option Todo.Account)
  address : Todo.Account → IO (Option String)
  signOut : Request Body.Stream → Todo.Account → IO Unit
  linked : Todo.Account → IO (List (Credential Todo.tenant))
  unlink : Todo.Account → CredentialId Todo.tenant → IO (Except Service.UnlinkRefusal Unit)

def Site.identity (s : Site) : Identity where
  of := identify s
  address := addressOf s
  signOut := signOut s
  linked := linked s
  unlink := unlink s

/-- Rebuilds the transport from `fresh` for every send.

A transport built once holds whatever it was given then, which is right for a provider token and
wrong for anything with an expiry on it. The failure that causes arrives hours after the process
started, on a send that looks no different from the ones that worked. -/
def refreshing {α : Type} (fresh : IO α) (transport : α → EmailTransport IO) :
    EmailTransport IO where
  send mail := do (transport (← fresh)).send mail

/-- Everything served under the tenant's own prefix, which is both libraries' routes over one
router. Two handlers would not do: the prefix is what the application splits on, so whichever ran
second would never be reached.

The fallback is the federated routes' page rather than the magic link's `unknown`, which is about
a link that has been used or has expired and would describe the wrong thing for a path that names
no route at all. -/
def Site.handler (s : Site) : StatelessHandler :=
  Routing.toHandler (Authentication.Http.routes s.http ++ s.federatedRoutes)
    (fun _ => Response.notFound.html Todo.notFoundPage)

end Todo.Auth
