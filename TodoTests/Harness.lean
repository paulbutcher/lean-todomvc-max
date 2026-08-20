/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Store

public section

namespace TodoTests

open Todo

def checkEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit :=
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {repr expected}, got {repr actual}"

/-- A `Store` the handler tests can drive directly. What the queries in `Todo.Db` do with the
same operations is settled against a real database in `TodoTests.runDbTests`; here the point is
only to give the handlers something to read and write. -/
def memoryStore (initial : Array Item) : IO Store := do
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
    toggle := fun id => do
      modifyItem id fun item => { item with completed := !item.completed }
    delete := fun id => do remove id
    setTitle := fun id raw => do
      match normalisedTitle raw with
      | none => remove id
      | some title => modifyItem id ({ · with title })
    toggleAll := do
      let anyActive := (← items.get).any (!·.completed)
      items.modify (·.map ({ · with completed := anyActive }))
    clearCompleted := do items.modify (·.filter (!·.completed))
  }

end TodoTests
