/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Postgres
public import Telemetry
public import Todo.Store

public section

namespace Todo.Db

open Postgres
open Postgres.Interpolation
open Std.Async (Async)
open Telemetry

deriving instance Postgres.Row for Item

def list (db : Conn) (account : Account) (filter : Filter) : IO (Array Item) := do
  let owner := account.value
  let stmt ← match filter with
    | .all =>
      db sql!"SELECT id, title, completed FROM todos WHERE account_id = {owner} ORDER BY id"
    | .active =>
      db sql!"SELECT id, title, completed FROM todos
                WHERE account_id = {owner} AND NOT completed ORDER BY id"
    | .completed =>
      db sql!"SELECT id, title, completed FROM todos
                WHERE account_id = {owner} AND completed ORDER BY id"
  stmt.results.toArray

def add (db : Conn) (account : Account) (title : String) : IO Unit :=
  match normalisedTitle title with
  | none => pure ()
  | some title =>
    let owner := account.value
    db exec!"INSERT INTO todos (account_id, title) VALUES ({owner}, {title})"

def toggle (db : Conn) (account : Account) (id : Int64) : IO Unit :=
  let owner := account.value
  db exec!"UPDATE todos SET completed = NOT completed WHERE id = {id} AND account_id = {owner}"

def delete (db : Conn) (account : Account) (id : Int64) : IO Unit :=
  let owner := account.value
  db exec!"DELETE FROM todos WHERE id = {id} AND account_id = {owner}"

def setTitle (db : Conn) (account : Account) (id : Int64) (title : String) : IO Unit :=
  match normalisedTitle title with
  | none => delete db account id
  | some title =>
    let owner := account.value
    db exec!"UPDATE todos SET title = {title} WHERE id = {id} AND account_id = {owner}"

/-- TodoMVC's "toggle all" semantics: complete everything if anything's active, otherwise reset
all to active. -/
def toggleAll (db : Conn) (account : Account) : IO Unit :=
  let owner := account.value
  transaction db (do
    let stmt ← db sql!"SELECT COUNT(*) FROM todos WHERE account_id = {owner} AND NOT completed"
    discard stmt.step
    let activeCount ← stmt.columnInt64 (0 : Int32)
    if activeCount > 0 then
      db exec!"UPDATE todos SET completed = TRUE WHERE account_id = {owner}"
    else
      db exec!"UPDATE todos SET completed = FALSE WHERE account_id = {owner}")

def clearCompleted (db : Conn) (account : Account) : IO Unit :=
  let owner := account.value
  db exec!"DELETE FROM todos WHERE completed AND account_id = {owner}"

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
  list account filter := spanned pool "SELECT" (list · account filter)
  add account title := spanned pool "INSERT" (add · account title)
  toggle account id := spanned pool "UPDATE" (toggle · account id)
  delete account id := spanned pool "DELETE" (delete · account id)
  setTitle account id title := spanned pool "UPDATE" (setTitle · account id title)
  toggleAll account := spanned pool "UPDATE" (toggleAll · account)
  clearCompleted account := spanned pool "DELETE" (clearCompleted · account)

end Todo.Db
