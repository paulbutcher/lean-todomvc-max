/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Postgres
import Telemetry
import Todo.Store

namespace Todo.Db

open Postgres
open Postgres.Interpolation
open Std.Async (Async)
open Telemetry

deriving instance Postgres.Row for Item

def list (db : Conn) (filter : Filter) : IO (Array Item) := do
  let stmt ← match filter with
    | .all => prepare db "SELECT id, title, completed FROM todos ORDER BY id"
    | .active => prepare db "SELECT id, title, completed FROM todos WHERE NOT completed ORDER BY id"
    | .completed => prepare db "SELECT id, title, completed FROM todos WHERE completed ORDER BY id"
  stmt.results.toArray

def add (db : Conn) (title : String) : IO Unit :=
  match normalisedTitle title with
  | none => pure ()
  | some title => db exec!"INSERT INTO todos (title) VALUES ({title})"

def toggle (db : Conn) (id : Int64) : IO Unit :=
  db exec!"UPDATE todos SET completed = NOT completed WHERE id = {id}"

def delete (db : Conn) (id : Int64) : IO Unit :=
  db exec!"DELETE FROM todos WHERE id = {id}"

def setTitle (db : Conn) (id : Int64) (title : String) : IO Unit :=
  match normalisedTitle title with
  | none => delete db id
  | some title => db exec!"UPDATE todos SET title = {title} WHERE id = {id}"

/-- TodoMVC's "toggle all" semantics: complete everything if anything's active, otherwise reset
all to active. -/
def toggleAll (db : Conn) : IO Unit :=
  transaction db (do
    let stmt ← prepare db "SELECT COUNT(*) FROM todos WHERE NOT completed"
    discard stmt.step
    let activeCount ← stmt.columnInt64 (0 : Int32)
    if activeCount > 0 then
      db exec!"UPDATE todos SET completed = TRUE"
    else
      db exec!"UPDATE todos SET completed = FALSE")

def clearCompleted (db : Conn) : IO Unit :=
  db exec!"DELETE FROM todos WHERE completed"

/-- The span covers the borrow as well as the statements, because `Pool.withConnAsync` is the only
way in and it does both. Waiting for a connection and running a query fail in entirely different
ways, so the two are worth telling apart, but separating them needs a pool that hands out a borrow
as a value rather than as a bracket. -/
private def spanned (pool : Pool) (operation : String) (act : Conn → IO α) :
    TelemetryT Async α :=
  spanning s!"{operation} todos" (liftM (pool.withConnAsync act)) (kind := .client)
    (attrs := [(Conventions.dbSystemName, "postgresql"), (Conventions.dbOperationName, operation)])

/-- One borrow per operation, which is the unit each of these is: a borrow is the extent over
which the pool guarantees a live connection, and `toggleAll`'s count and update have to see the
same one for its transaction to mean anything. Nothing here sets session state, so nothing depends
on a later borrow landing on the same connection.

`setTitle` and `toggleAll` are named for the statement they exist to run; each has a second path
(a delete, and a count that decides the direction) which the span does not separate out. -/
def store (pool : Pool) : Store where
  list filter := spanned pool "SELECT" (list · filter)
  add title := spanned pool "INSERT" (add · title)
  toggle id := spanned pool "UPDATE" (toggle · id)
  delete id := spanned pool "DELETE" (delete · id)
  setTitle id title := spanned pool "UPDATE" (setTitle · id title)
  toggleAll := spanned pool "UPDATE" toggleAll
  clearCompleted := spanned pool "DELETE" clearCompleted

end Todo.Db
