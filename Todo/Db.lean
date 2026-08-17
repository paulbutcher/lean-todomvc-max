/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Postgres
import Todo.Store

namespace Todo.Db

open Postgres
open Postgres.Interpolation

deriving instance Postgres.Row for Item

def initSchema (db : Conn) : IO Unit :=
  db exec!"
    CREATE TABLE IF NOT EXISTS todos (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      title TEXT NOT NULL,
      completed BOOLEAN NOT NULL DEFAULT FALSE
    )"

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

def store (db : Conn) : Store where
  list := list db
  add := add db
  toggle := toggle db
  delete := delete db
  setTitle := setTitle db
  toggleAll := toggleAll db
  clearCompleted := clearCompleted db

end Todo.Db
