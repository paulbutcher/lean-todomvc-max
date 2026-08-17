/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Test.Helpers
import Todo.App
import TodoTests.Harness

namespace TodoTests

open Todo
open Std.Async (Async)
open Std.Http.Internal.Test
open Telemetry (runTelemetry)

private def active : Item := { id := 1, title := "alpha", completed := false }
private def completed : Item := { id := 2, title := "beta", completed := true }

private def handlerOf (initial : Array Item) : IO TestHandler := do
  pure (Todo.app (← memoryStore initial)).onRequest

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
  let store ← memoryStore #[]
  check "POST /todos" (mkPost "/todos" "" "Connection: close\x0d\n") (Todo.app store).onRequest
    fun response => do
      assertStatus response "HTTP/1.1 400"
  checkEq "nothing was created" (0 : Nat)
    (← Async.block (runTelemetry (store.list .all))).size

private def serverOf (https : Bool) : IO TestHandler := do
  let store ← memoryStore #[]
  let sessions ← Middleware.MemoryStore.new
  pure (Todo.server store sessions (https := https)).onRequest

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

def runAppTests : IO Unit :=
  runGroup "Todo.App" do
    testPageFiltersItemsButCountsThemAll
    testMutationRendersTheDisplayedFilter
    testEditingAnItemThatIsGone
    testCreateWithoutATitle
    testTlsProfileGatesCookieAndHsts

end TodoTests
