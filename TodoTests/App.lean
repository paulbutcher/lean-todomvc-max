/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.App
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Std.Async (Async)
open Std.Http.Internal.Test
open Telemetry (runTelemetry)

private def active : Item := { id := 1, title := "alpha", completed := false }
private def completed : Item := { id := 2, title := "beta", completed := true }

private def signedInAs (account : Account) (initial : Array Item) : IO TestHandler := do
  let store ← memoryStore account initial
  pure (Todo.app (fixedIdentity account (← IO.mkRef 0)) store
    (← scriptedAssistant #[]) noGrants).onRequest

private def handlerOf (initial : Array Item) : IO TestHandler := signedInAs alice initial

/-- The list a page shows is the filtered one, but the count it reports is over every item, so a
filtered view still tells you how much is left overall. -/
private def testPageFiltersItemsButCountsThemAll : IO Unit := do
  check "GET /completed" (mkGetClose "/completed") (← handlerOf #[active, completed])
    fun response => do
      assertContains response "beta"
      assertAbsent response "alpha"
      assertContains response "1 item left"

private def toggleFrom (currentUrl : String) (expect : ByteArray → IO Unit) : IO Unit := do
  check s!"POST /todos/1/toggle from {currentUrl}"
    (mkPost "/todos/1/toggle" "" s!"HX-Current-URL: {currentUrl}\x0d\nConnection: close\x0d\n")
    (← handlerOf #[active, completed]) expect

/-- After a mutation the client gets back the list for the URL it is displaying, which is the
only thing that tells the handler which filter to re-render. -/
private def testMutationRendersTheDisplayedFilter : IO Unit := do
  -- Toggling `active` leaves nothing active, so a client viewing /active gets an empty list.
  toggleFrom "http://example.com/active" fun response => do
    assertAbsent response "alpha"
    assertAbsent response "beta"
  toggleFrom "http://example.com/completed" fun response => do
    assertContains response "alpha"
    assertContains response "beta"

private def testEditingAnItemThatIsGone : IO Unit := do
  check "GET /todos/99/edit" (mkGetClose "/todos/99/edit") (← handlerOf #[active])
    fun response => assertStatus response "HTTP/1.1 404"

/-- A request that arrives without a parsed `title` is refused rather than creating an item with
no title, so a missing or unparsed form body can't reach storage. -/
private def testCreateWithoutATitle : IO Unit := do
  let store ← memoryStore alice #[]
  check "POST /todos" (mkPost "/todos" "" "Connection: close\x0d\n")
    (Todo.app (fixedIdentity alice (← IO.mkRef 0)) store (← scriptedAssistant #[])
      noGrants).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 400"
  checkEq "nothing was created" (0 : Nat)
    (← Async.block (runTelemetry (store.list alice .all))).size

/-- Every route needs a signed-in account, and one that hasn't got one is sent to sign in rather
than shown somebody's list or told the item it named does not exist. -/
private def testAnonymousRequestsAreSentToSignIn : IO Unit := do
  let store ← memoryStore alice #[active]
  let handler :=
    (Todo.app anonymousIdentity store (← scriptedAssistant #[]) noGrants).onRequest
  check "GET / with no session" (mkGetClose "/") handler fun response => do
    assertStatus response "HTTP/1.1 303"
    assertContains response "/t/todomvc/signin"
    assertAbsent response "alpha"

/-- HTMX follows a redirect itself and swaps what it finds into the element it was targeting,
which would paste the sign-in page into the todo list. A session that lapses mid-page has to make
the browser navigate instead. -/
private def testAnonymousHtmxRequestsAreToldToNavigate : IO Unit := do
  let store ← memoryStore alice #[active]
  check "POST /todos/1/toggle with no session"
    (mkPost "/todos/1/toggle" "" "HX-Request: true\x0d\nConnection: close\x0d\n")
    (Todo.app anonymousIdentity store (← scriptedAssistant #[]) noGrants).onRequest
    fun response => do
      assertContains response "Redirect: /t/todomvc/signin"
      assertAbsent response "HTTP/1.1 303"

/-- The account is what scopes a list, and an id from somebody else's is not a way around it:
reading finds nothing and mutating changes nothing. -/
private def testOneAccountCannotReachAnother : IO Unit := do
  let store ← memoryStore alice #[active]
  let asBob :=
    (Todo.app (fixedIdentity bob (← IO.mkRef 0)) store (← scriptedAssistant #[])
      noGrants).onRequest
  check "GET / as another account" (mkGetClose "/") asBob fun response =>
    assertAbsent response "alpha"
  check "DELETE another account's item"
    "DELETE /todos/1 HTTP/1.1\x0d\nHost: example.com\x0d\nConnection: close\x0d\n\x0d\n"
    asBob fun _ => pure ()
  checkEq "the item is still there" #["alpha"]
    ((← Async.block (runTelemetry (store.list alice .all))).map (·.title))

/-- Signing out has to do both halves. Revoking without clearing leaves the browser sending a
credential on every request until it expires, and clearing without revoking leaves one that still
works in the hands of whoever recovers the cookie. -/
private def testSignOutRevokesAndClearsTheCookie : IO Unit := do
  let store ← memoryStore alice #[]
  let revocations ← IO.mkRef 0
  check "POST /signout" (mkPost "/signout" "" "Connection: close\x0d\n")
    (Todo.app (fixedIdentity alice revocations) store (← scriptedAssistant #[])
      noGrants).onRequest
    fun response => do
      assertContains response "auth_session="
      assertContains response "Max-Age=0"
  checkEq "the session was revoked as well" 1 (← revocations.get)

private def serverOf (https : Bool) : IO TestHandler := do
  let store ← memoryStore alice #[]
  let sessions ← Middleware.MemoryStore.new
  let auth : Std.Http.Server.StatelessHandler :=
    { onRequest := fun _ => Std.Http.Response.ok.html "sign in" }
  pure (Todo.server (fixedIdentity alice (← IO.mkRef 0)) auth store (← scriptedAssistant #[])
    sessions noGrants (https := https)).onRequest

/-- Only a deployment with something terminating TLS in front of it may mark the session cookie
`secure` or claim `hsts`. The permissive direction is the harmful one: a `secure` cookie sent over
plain http never comes back, and `antiForgery` then rejects every mutation. -/
private def testTlsProfileGatesCookieAndHsts : IO Unit := do
  check "behind a TLS terminator" (mkGetClose "/") (← serverOf true)
    fun response => do
      assertContains response "Strict-Transport-Security"
      assertContains response "; Secure"
  check "served directly over http" (mkGetClose "/") (← serverOf false)
    fun response => do
      assertAbsent response "Strict-Transport-Security"
      assertAbsent response "; Secure"

/-- The sign-in routes carry an anti-forgery token of their own and the browser reaching them has
no session for `antiForgery` to have put one in, so they are served outside it. A `POST` there
that `antiForgery` would have refused has to arrive. -/
private def testSignInRoutesAreServedOutsideAntiForgery : IO Unit := do
  let store ← memoryStore alice #[]
  let sessions ← Middleware.MemoryStore.new
  let auth : Std.Http.Server.StatelessHandler :=
    { onRequest := fun _ => Std.Http.Response.ok.html "the sign-in routes answered" }
  let handler :=
    (Todo.server anonymousIdentity auth store (← scriptedAssistant #[]) sessions
      noGrants).onRequest
  check "POST /t/todomvc/signin with no token"
    (mkPost "/t/todomvc/signin" "email=someone@example.com" "Connection: close\x0d\n") handler
    fun response => do
      assertContains response "the sign-in routes answered"
  check "POST /todos with no token" (mkPost "/todos" "title=x" "Connection: close\x0d\n") handler
    fun response => assertStatus response "HTTP/1.1 403"

def runAppTests : IO Unit :=
  runGroup "Todo.App" do
    testPageFiltersItemsButCountsThemAll
    testMutationRendersTheDisplayedFilter
    testEditingAnItemThatIsGone
    testCreateWithoutATitle
    testAnonymousRequestsAreSentToSignIn
    testAnonymousHtmxRequestsAreToldToNavigate
    testOneAccountCannotReachAnother
    testSignOutRevokesAndClearsTheCookie
    testTlsProfileGatesCookieAndHsts
    testSignInRoutesAreServedOutsideAntiForgery

end TodoTests
