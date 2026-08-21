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
public import Todo.AuthViews
public import Todo.Tenant

public section

open Authentication
open Authentication.Sql
open Std Http
open Std.Http.Server

namespace Todo.Auth

/-! ## The pool as a SQL driver -/

/-- `none` is a statement that has not been given a connection and draws its own; `some` is one
running inside a transaction, which has to reach the connection the `BEGIN` ran on. -/
private def borrowed {α : Type} (pool : _root_.Postgres.Pool)
    (handle : Option _root_.Postgres.Conn) (act : _root_.Postgres.Conn → IO α) : IO α :=
  match handle with
  | some conn => act conn
  | none => pool.withConn act

/-- Integers travel as text because Postgres infers a parameter's type from what it is compared
against, and nothing here compares one against anything ambiguous. -/
private def bind (stmt : _root_.Postgres.Stmt) (params : Array SqlValue) : IO Unit := do
  let mut position : Int32 := 1
  for value in params do
    match value with
    | .null => stmt.bindNull position
    | .text text => stmt.bindText position text
    | .int number => stmt.bindText position (toString number)
    position := position + 1

private def readRow (stmt : _root_.Postgres.Stmt) (columns : Nat) : IO SqlRow := do
  let mut row : SqlRow := #[]
  for index in [0 : columns] do
    let position := Int32.ofNat index
    row := row.push <| ←
      if ← stmt.columnIsNull position then pure .null
      else do pure (.text (← stmt.columnText position))
  pure row

private def prepared (conn : _root_.Postgres.Conn) (text : String) (params : Array SqlValue) :
    IO _root_.Postgres.Stmt := do
  let stmt ← _root_.Postgres.prepare conn text
  bind stmt params
  pure stmt

/-- The library's driver seam over the pool the application already has, so authentication does
not open a connection of its own and its share of the database is bounded by the same pool as
everything else.

A statement outside a transaction is self-contained, so it borrows for its own duration and
gives the connection straight back. A transaction borrows once and hands the block what it
borrowed, which is what keeps its `BEGIN`, its statements and its `COMMIT` on one connection.

The borrow blocks the fiber's thread rather than suspending it, unlike `Todo.Db`. The library's
ports are `IO`, so there is nowhere for an `Async` to go. -/
def connection (pool : _root_.Postgres.Pool) : SqlConnection IO where
  handle := (none : Option _root_.Postgres.Conn)
  query handle text params := borrowed pool handle fun conn => do
    let stmt ← prepared conn text params
    let mut rows : Array SqlRow := #[]
    let mut columns := 0
    while ← stmt.step do
      if rows.isEmpty then
        columns ← stmt.columnCount
      rows := rows.push (← readRow stmt columns)
    pure rows
  exec handle text params := borrowed pool handle fun conn => do
    let stmt ← prepared conn text params
    discard stmt.step
    pure ((← stmt.commandTuples).getD 0).toNatClampNeg
  -- A block reached from inside a transaction joins the one already open, which is what both
  -- backends the library ships do.
  runTransaction handle action :=
    match handle with
    | some conn => action (some conn)
    | none => pool.withConn fun conn => _root_.Postgres.transaction conn (action (some conn))

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
  sender : SendingIdentity
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
server, which is where this one came from.

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

def ports (pool : _root_.Postgres.Pool) (settings : Settings) : Service.Ports IO where
  store := sqlAuthStore Authentication.Postgres.dialect (connection pool)
  transport := settings.transport
  responsePolicy := responsePolicy
  limiter := rateLimiter Authentication.Postgres.dialect (connection pool)
  responseFloor := ResponseFloor.sleeping 400
  humanCheck := HumanCheck.unchecked IO
  peppers := { current := settings.pepper }

/-- Generic in the tenant so that the lookup below can answer for the one it was asked about
rather than having to prove it is the one this application has. -/
def tenantConfig (settings : Settings) (t : TenantId) : TenantConfig t where
  displayName := "TodoMVC"
  baseUrl := settings.baseUrl
  sendingIdentity := settings.sender
  signupPolicy := .unrestricted
  -- The application is mounted at the root, so a session cookie confined to the tenant's own
  -- path would never be offered to any route that needs it.
  sessionCookiePath := "/"
  returnToAllowlist := ["/", "/active", "/completed"]

structure Site where
  ports : Service.Ports IO
  settings : Settings

def site (pool : _root_.Postgres.Pool) (settings : Settings) : Site where
  ports := ports pool settings
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
