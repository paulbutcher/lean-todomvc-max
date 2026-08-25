/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Authentication.Instances
public import AuthenticationHttp
public import AuthenticationPostgres
public import Postgres
public import Middleware
public import Todo.AuthMail
public import Todo.Authorization
public import Todo.AuthViews
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
  returnToAllowlist := ["/", "/active", "/completed", Routes.links.oauthAuthorize]

structure Site where
  ports : Service.Ports IO
  authorization : Todo.Authorization.Site
  settings : Settings

def site (pool : _root_.Postgres.Pool) (settings : Settings) : Site where
  ports := ports pool settings
  authorization :=
    Todo.Authorization.site (Todo.Authorization.ports pool { current := settings.pepper })
      settings.baseUrl
  settings

namespace Site

def config (s : Site) : TenantConfig Todo.tenant := tenantConfig s.settings Todo.tenant

/-- A tenant this application does not recognise is answered the way an unrouted path is, which
is the library's requirement and costs nothing here: there is only ever one. -/
def http (s : Site) : Authentication.Http.Config where
  ports := s.ports
  pages := Todo.pages
  tenant := fun t => pure (if t == Todo.tenant then some (tenantConfig s.settings t) else none)

end Site

/-! ## Reading the session -/

def sessionCookie : String := "auth_session"

private def presented (req : Request Body.Stream) : Option CredentialValue :=
  ((req.extensions.get Middleware.Cookies).bind (·.get sessionCookie)).map (⟨·⟩)

/-- Who the request is, or nobody. -/
private def identify (s : Site) (req : Request Body.Stream) : IO (Option Todo.Account) := do
  match presented req with
  | none => pure none
  | some credential =>
    pure ((← Service.identify s.ports s.config credential).map (·.account))

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

/-- What the application needs of a signed-in person, as operations rather than as the `Site`
they are reached through. Same reason `Todo.Store` is a record: the handlers can then be driven
without a database, and what happens against a real one is settled where it happens.

Each is `IO` because that is what the library ports are. -/
structure Identity where
  of : Request Body.Stream → IO (Option Todo.Account)
  address : Todo.Account → IO (Option String)
  signOut : Request Body.Stream → Todo.Account → IO Unit

def Site.identity (s : Site) : Identity where
  of := identify s
  address := addressOf s
  signOut := signOut s

/-- Rebuilds the transport from `fresh` for every send.

A transport built once holds whatever it was given then, which is right for a provider token and
wrong for anything with an expiry on it. The failure that causes arrives hours after the process
started, on a send that looks no different from the ones that worked. -/
def refreshing {α : Type} (fresh : IO α) (transport : α → EmailTransport IO) :
    EmailTransport IO where
  send mail := do (transport (← fresh)).send mail

/-- The sign-in routes, ready to be mounted. -/
def Site.handler (s : Site) : StatelessHandler := Authentication.Http.handler s.http

end Todo.Auth
