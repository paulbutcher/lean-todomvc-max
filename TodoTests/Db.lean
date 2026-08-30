/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Postgres
public import Todo.Db
public import Todo.Migrations
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Postgres
open Std.Async (Async)
open Telemetry (runTelemetry)

/-- Runs `action` against a schema of this run's own, so a test run never touches the `todos` the
application itself holds, and concurrent runs against one server stay out of each other's way.
Dropping first covers the remains of an earlier run that was killed before it could clean up.

The authentication library's own migrations name their `auth` schema outright, so those tables are
shared rather than per run. Nothing here reads or writes them; they are created because `migrate`
applies every migration it finds.

The schema name is passed on as well as being set here, because `SET search_path` reaches only
this connection and a test wanting a pool has to put the schema where every connection in it will
pick the schema up. -/
private def withTestSchema (action : Conn → String → IO α) : IO α := do
  let db ← Postgres.open ""
  let schema := s!"todomvc_test_{← IO.Process.getPID}"
  execScript db s!"DROP SCHEMA IF EXISTS {schema} CASCADE;
    CREATE SCHEMA {schema};
    SET search_path TO {schema}"
  try
    Todo.migrate db
    action db schema
  finally
    execScript db s!"DROP SCHEMA IF EXISTS {schema} CASCADE"

private def withEmptyTable (db : Conn) (action : IO α) : IO α := do
  execScript db "TRUNCATE todos RESTART IDENTITY"
  action

private def titlesOf (items : Array Item) : Array String := items.map (·.title)

private def testAddStoresWhatNormalisationAdmits (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db alice "  "
    checkEq "a blank title never reaches the table" (#[] : Array String)
      (titlesOf (← Db.list db alice .all))
    Db.add db alice "  Buy milk  "
    Db.add db alice "Wash car"
    checkEq "titles come back trimmed, oldest first" #["Buy milk", "Wash car"]
      (titlesOf (← Db.list db alice .all))

private def testSetTitleBlankDeletes (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db alice "Buy milk"
    let [item] := (← Db.list db alice .all).toList
      | throw (IO.userError "expected exactly one item")
    Db.setTitle db alice item.id "   "
    checkEq "editing a title down to blank deletes the row" (0 : Nat)
      (← Db.list db alice .all).size

private def testToggleAll (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.toggleAll db alice
    checkEq "toggleAll on empty table" (0 : Nat) (← Db.list db alice .all).size
    Db.add db alice "a"; Db.add db alice "b"
    Db.toggleAll db alice
    checkEq "toggleAll completes all when any active"
      #[true, true] ((← Db.list db alice .all).map (·.completed))
    Db.toggleAll db alice
    checkEq "toggleAll un-completes all when none active"
      #[false, false] ((← Db.list db alice .all).map (·.completed))

private def testListFiltersAndClearCompleted (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db alice "a"; Db.add db alice "b"; Db.add db alice "c"
    let [x, _y, z] := (← Db.list db alice .all).toList
      | throw (IO.userError "expected exactly three items")
    Db.toggle db alice x.id
    Db.toggle db alice z.id
    checkEq "active filter excludes completed" #["b"] (titlesOf (← Db.list db alice .active))
    checkEq "completed filter excludes active" #["a", "c"]
      (titlesOf (← Db.list db alice .completed))
    Db.clearCompleted db alice
    checkEq "clearCompleted removes only completed rows" #["b"]
      (titlesOf (← Db.list db alice .all))

/-- The `WHERE` clause every statement carries, tested where it lives. An id here is a small
integer a neighbouring account can simply name, so reading, editing, toggling and deleting have
each to find nothing rather than find somebody else's row. -/
private def testStatementsAreScopedToTheAccount (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db alice "alice's"
    Db.add db bob "bob's"
    let [item] := (← Db.list db alice .all).toList
      | throw (IO.userError "expected alice to have exactly one item")
    checkEq "a list holds only the account's own rows" #["bob's"]
      (titlesOf (← Db.list db bob .all))
    Db.toggle db bob item.id
    Db.setTitle db bob item.id "taken over"
    Db.delete db bob item.id
    Db.clearCompleted db bob
    Db.toggleAll db bob
    checkEq "nothing another account did reached it" #[item] (← Db.list db alice .all)

/-- A `Store` reaching the same schema through a pool rather than through one connection. -/
private def storeFor (schema : String) : IO Store := do
  Db.store <$> Pool.create s!"options='-c search_path={schema}'" 4

/-- Every request the server accepts is handled in its own fiber, so store operations genuinely
overlap; a libpq connection cannot be used concurrently, which is what the pool behind `Db.store`
is there for. Twelve overlapping writes through a pool of four must all take effect exactly once,
where a store sharing a single connection between them corrupts the protocol instead. -/
private def testConcurrentWrites (db : Conn) (schema : String) : IO Unit :=
  withEmptyTable db do
    let store ← storeFor schema
    let writes := 12
    let tasks ← (List.range writes).toArray.mapM fun i =>
      IO.asTask (Async.block (runTelemetry (store.add alice s!"item {i}")))
    for task in tasks do
      match ← IO.wait task with
      | .ok _ => pure ()
      | .error e => throw e
    checkEq "every overlapping write landed exactly once" writes
      (← Async.block (runTelemetry (store.list alice .all))).size

/-- A message as something a failure can be reported through, since `LLMClient.Msg` has no `Repr`.
Every field the table holds is in here, so a column read back into the wrong one shows up. -/
private def shapeOf : LLMClient.Msg → String × String × String × Bool
  | .user text => ("user", text, "", false)
  | .assistant text calls => ("assistant", text, Json.compress (toolCallsJson calls), false)
  | .toolResult id output isError _ => ("tool", output, id, isError)

/-- The transcript survives the trip through the columns it is kept in, tool calls and all. A
failed call is among them: it is the one message whose meaning is carried by something other than
its text, and a column that came back false would turn it into an ordinary result.
`toMsg_ofMsg` settles the encoding itself; this is the half of the round trip that theorem
deliberately does not reach, where the model's arbitrary JSON becomes column text and back, and
where `Postgres.Row` matches fields to columns by position rather than by name. -/
private def testChatMessagesSurviveTheTable (db : Conn) : IO Unit := do
  execScript db "TRUNCATE chat_messages RESTART IDENTITY"
  let call : LLMClient.ToolCall :=
    { id := "call-1", name := "add_todo"
      input := Json.mkObj [("title", "buy milk"), ("urgent", true)] }
  let written : Array LLMClient.Msg :=
    #[.user "add buy milk", .assistant "Adding it." #[call], .toolResult "call-1" "added",
      .toolResult "call-2" "that title is blank, so nothing was added" true]
  Db.chatAppend db alice written
  Db.chatAppend db bob #[.user "somebody else's"]
  checkEq "read back in the order they were written, unaltered" (written.map shapeOf)
    ((← Db.chatHistory db alice).map shapeOf)
  checkEq "and one account's conversation is not another's"
    #[("user", "somebody else's", "", false)] ((← Db.chatHistory db bob).map shapeOf)
  Db.chatClear db alice
  checkEq "clearing forgets one account's" 0 (← Db.chatHistory db alice).size
  checkEq "and leaves the other's" 1 (← Db.chatHistory db bob).size

def runDbTests : IO Unit :=
  withTestSchema fun db schema => do
    testAddStoresWhatNormalisationAdmits db
    testSetTitleBlankDeletes db
    testToggleAll db
    testListFiltersAndClearCompleted db
    testStatementsAreScopedToTheAccount db
    testChatMessagesSurviveTheTable db
    testConcurrentWrites db schema

end TodoTests
