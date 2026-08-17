/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Postgres
import Todo.Db
import Todo.Migrations
import TodoTests.Harness

namespace TodoTests

open Todo
open Postgres
open Std.Async (Async)
open Telemetry (runTelemetry)

/-- Runs `action` against a schema of this run's own, so a test run never touches the tables the
application itself uses, and concurrent runs against one server stay out of each other's way.
Dropping first covers the remains of an earlier run that was killed before it could clean up.

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
    Db.add db "  "
    checkEq "a blank title never reaches the table" (#[] : Array String)
      (titlesOf (← Db.list db .all))
    Db.add db "  Buy milk  "
    Db.add db "Wash car"
    checkEq "titles come back trimmed, oldest first" #["Buy milk", "Wash car"]
      (titlesOf (← Db.list db .all))

private def testSetTitleBlankDeletes (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db "Buy milk"
    let [item] := (← Db.list db .all).toList | throw (IO.userError "expected exactly one item")
    Db.setTitle db item.id "   "
    checkEq "editing a title down to blank deletes the row" (0 : Nat) (← Db.list db .all).size

private def testToggleAll (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.toggleAll db
    checkEq "toggleAll on empty table" (0 : Nat) (← Db.list db .all).size
    Db.add db "a"; Db.add db "b"
    Db.toggleAll db
    checkEq "toggleAll completes all when any active"
      #[true, true] ((← Db.list db .all).map (·.completed))
    Db.toggleAll db
    checkEq "toggleAll un-completes all when none active"
      #[false, false] ((← Db.list db .all).map (·.completed))

private def testListFiltersAndClearCompleted (db : Conn) : IO Unit :=
  withEmptyTable db do
    Db.add db "a"; Db.add db "b"; Db.add db "c"
    let [x, _y, z] := (← Db.list db .all).toList
      | throw (IO.userError "expected exactly three items")
    Db.toggle db x.id
    Db.toggle db z.id
    checkEq "active filter excludes completed" #["b"] (titlesOf (← Db.list db .active))
    checkEq "completed filter excludes active" #["a", "c"] (titlesOf (← Db.list db .completed))
    Db.clearCompleted db
    checkEq "clearCompleted removes only completed rows" #["b"] (titlesOf (← Db.list db .all))

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
      IO.asTask (Async.block (runTelemetry (store.add s!"item {i}")))
    for task in tasks do
      match ← IO.wait task with
      | .ok _ => pure ()
      | .error e => throw e
    checkEq "every overlapping write landed exactly once" writes
      (← Async.block (runTelemetry (store.list .all))).size

def runDbTests : IO Unit :=
  withTestSchema fun db schema => do
    testAddStoresWhatNormalisationAdmits db
    testSetTitleBlankDeletes db
    testToggleAll db
    testListFiltersAndClearCompleted db
    testConcurrentWrites db schema

end TodoTests
