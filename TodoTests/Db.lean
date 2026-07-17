import SQLite
import Todo.Db

namespace TodoTests

open Todo

private def checkEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit :=
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {repr expected}, got {repr actual}"

private def freshDb : IO SQLite := do
  let db ← SQLite.open ":memory:"
  initSchema db
  pure db

private def testAddSkipsBlank : IO Unit := do
  let db ← freshDb
  add db "  "
  checkEq "blank title inserts nothing" (#[] : Array String) ((← list db .all).map (·.title))
  add db "  Buy milk  "
  checkEq "non-blank title is trimmed" #["Buy milk"] ((← list db .all).map (·.title))

#eval testAddSkipsBlank

private def testSetTitleEmptyDeletes : IO Unit := do
  let db ← freshDb
  add db "Buy milk"
  let [item] := (← list db .all).toList | throw (IO.userError "expected exactly one item")
  setTitle db item.id "   "
  checkEq "empty edited title deletes the row" (0 : Nat) (← list db .all).size
  add db "Wash car"
  let [item2] := (← list db .all).toList | throw (IO.userError "expected exactly one item")
  setTitle db item2.id "  Wash the car  "
  checkEq "non-blank edited title is trimmed" #["Wash the car"] ((← list db .all).map (·.title))

#eval testSetTitleEmptyDeletes

private def testToggleAll : IO Unit := do
  let db ← freshDb
  toggleAll db
  checkEq "toggleAll on empty table" (0 : Nat) (← list db .all).size
  add db "a"; add db "b"
  toggleAll db
  checkEq "toggleAll completes all when any active" #[true, true] ((← list db .all).map (·.completed))
  toggleAll db
  checkEq "toggleAll un-completes all when none active" #[false, false] ((← list db .all).map (·.completed))

#eval testToggleAll

private def testListFiltersAndClearCompleted : IO Unit := do
  let db ← freshDb
  add db "a"; add db "b"; add db "c"
  let items ← list db .all
  let [x, _y, z] := items.toList | throw (IO.userError "expected exactly three items")
  toggle db x.id
  toggle db z.id
  checkEq "active filter excludes completed" #["b"] ((← list db .active).map (·.title))
  checkEq "completed filter excludes active" #["a", "c"] ((← list db .completed).map (·.title))
  clearCompleted db
  checkEq "clearCompleted removes only completed rows" #["b"] ((← list db .all).map (·.title))

#eval testListFiltersAndClearCompleted

end TodoTests
