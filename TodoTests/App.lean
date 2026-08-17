/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Test.Helpers
import Todo.App
import TodoTests.Harness

namespace TodoTests

open Todo
open Std.Http.Internal.Test

/-- A `Store` the handler tests can drive directly. What the queries in `Todo.Db` do with the
same operations is settled against a real database in `TodoTests.runDbTests`; here the point is
only to give the handlers something to read and write. -/
private def memoryStore (initial : Array Item) : IO Store := do
  let items ← IO.mkRef initial
  let nextId ← IO.mkRef ((initial.map (·.id)).foldl max 0 + 1)
  let modifyItem (id : Int64) (f : Item → Item) : IO Unit :=
    items.modify (·.map fun item => if item.id == id then f item else item)
  let remove (id : Int64) : IO Unit := items.modify (·.filter (·.id != id))
  pure {
    list := fun filter => do
      pure <| (← items.get).filter fun item =>
        match filter with
        | .all => true
        | .active => !item.completed
        | .completed => item.completed
    add := fun raw => do
      if let some title := normalisedTitle raw then
        let id ← nextId.modifyGet fun id => (id, id + 1)
        items.modify (·.push { id, title, completed := false })
    toggle := fun id => modifyItem id fun item => { item with completed := !item.completed }
    delete := remove
    setTitle := fun id raw =>
      match normalisedTitle raw with
      | none => remove id
      | some title => modifyItem id ({ · with title })
    toggleAll := do
      let anyActive := (← items.get).any (!·.completed)
      items.modify (·.map ({ · with completed := anyActive }))
    clearCompleted := items.modify (·.filter (!·.completed))
  }

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
  checkEq "nothing was created" (0 : Nat) (← store.list .all).size

def runAppTests : IO Unit :=
  runGroup "Todo.App" do
    testPageFiltersItemsButCountsThemAll
    testMutationRendersTheDisplayedFilter
    testEditingAnItemThatIsGone
    testCreateWithoutATitle

end TodoTests
