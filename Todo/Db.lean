/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Postgres
public import Telemetry
public import Todo.Store
public import Todo.Chat

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

def setCompleted (db : Conn) (account : Account) (id : Int64) (completed : Bool) : IO Unit :=
  let owner := account.value
  db exec!"UPDATE todos SET completed = {completed} WHERE id = {id} AND account_id = {owner}"

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
private def spanned (pool : Pool) (operation table : String) (act : Conn → IO α) :
    TelemetryT Async α :=
  spanning s!"{operation} {table}" (liftM (pool.withConnAsync act)) (kind := .client)
    (attrs := [(Conventions.dbSystemName, "postgresql"), (Conventions.dbOperationName, operation),
               ("db.collection.name", .str table)])

/-- One borrow per operation, which is the unit each of these is: a borrow is the extent over
which the pool guarantees a live connection, and `toggleAll`'s count and update have to see the
same one for its transaction to mean anything. Nothing here sets session state, so nothing depends
on a later borrow landing on the same connection.

`setTitle` and `toggleAll` are named for the statement they exist to run; each has a second path
(a delete, and a count that decides the direction) which the span does not separate out. -/
def store (pool : Pool) : Store where
  list account filter := spanned pool "SELECT" "todos" (list · account filter)
  add account title := spanned pool "INSERT" "todos" (add · account title)
  toggle account id := spanned pool "UPDATE" "todos" (toggle · account id)
  delete account id := spanned pool "DELETE" "todos" (delete · account id)
  setTitle account id title := spanned pool "UPDATE" "todos" (setTitle · account id title)
  setCompleted account id done := spanned pool "UPDATE" "todos" (setCompleted · account id done)
  toggleAll account := spanned pool "UPDATE" "todos" (toggleAll · account)
  clearCompleted account := spanned pool "DELETE" "todos" (clearCompleted · account)

/-! ## The chat transcript -/

/-- The columns as `SELECT` below reads them, which is what `Postgres.Row` derives against. It
carries `tool_calls` as the text a column holds; `Todo.ChatRow` is the same message once that text
has been read as JSON, and `toMsg_ofMsg` is stated over that rather than this. -/
private structure ChatMessageRow where
  role : String
  body : String
  toolCalls : String
  toolCallId : String
  isError : Bool
deriving Postgres.Row

/-- Unparseable `tool_calls` is read as no tool calls rather than as a reason to refuse the whole
transcript. Only this module writes the column, and it writes what `Json.compress` produced, so
the case is one a corrupted or hand-edited row reaches; losing what the model asked for is worse
for the person reading than losing the conversation around it. -/
def chatHistory (db : Conn) (account : Account) : IO (Array LLMClient.Msg) := do
  let owner := account.value
  let stmt ← db sql!"SELECT role, body, tool_calls, tool_call_id, is_error FROM chat_messages
                       WHERE account_id = {owner} ORDER BY id"
  let rows : Array ChatMessageRow ← stmt.results.toArray
  pure <| rows.map fun row =>
    ChatRow.toMsg
      { role := row.role, body := row.body, toolCallId := row.toolCallId, isError := row.isError
        toolCalls := (Json.parse row.toolCalls).toOption.getD (Json.arr #[]) }

def chatAppend (db : Conn) (account : Account) (msgs : Array LLMClient.Msg) : IO Unit := do
  let owner := account.value
  for msg in msgs do
    let row := ChatRow.ofMsg msg
    let toolCalls := Json.compress row.toolCalls
    db exec!"INSERT INTO chat_messages (account_id, role, body, tool_calls, tool_call_id, is_error)
               VALUES ({owner}, {row.role}, {row.body}, {toolCalls}, {row.toolCallId},
                       {row.isError})"

def chatClear (db : Conn) (account : Account) : IO Unit :=
  let owner := account.value
  db exec!"DELETE FROM chat_messages WHERE account_id = {owner}"

/-- One borrow for a whole `append`, so the messages of a turn arrive together. They are written
in one order and read back in it, and a reader that caught the middle of the write would see the
model's reply without the tool results it was drawn from. -/
def chatStore (pool : Pool) : ChatStore where
  history account := spanned pool "SELECT" "chat_messages" (chatHistory · account)
  append account msgs := spanned pool "INSERT" "chat_messages" (chatAppend · account msgs)
  clear account := spanned pool "DELETE" "chat_messages" (chatClear · account)

end Todo.Db
