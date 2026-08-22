/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import LLMClient
public import Todo.Store
public import Todo.Chat

public section

open Std.Async (Async)
open Telemetry (SpanContext TelemetryT)

namespace Todo.ChatTools

open LLMClient (Tool)

/-! ## What the model is offered -/

private def stringParam (description : String) : Json :=
  Json.mkObj [("type", "string"), ("description", description)]

private def integerParam (description : String) : Json :=
  Json.mkObj [("type", "integer"), ("description", description)]

private def schema (properties : List (String × Json)) (required : List String) : Json :=
  Json.mkObj
    [ ("type", "object"),
      ("properties", Json.mkObj properties),
      ("required", Json.arr (required.map (Json.str ·)).toArray) ]

/-- The id in every schema below is the one `list_todos` reports, and the descriptions say so.
A model that has not listed yet has no id it could have invented, which is what keeps it from
guessing at one; an id it guesses anyway belongs to somebody else's list or to nothing, and the
store's own account filter makes both a no-op rather than a stranger's item. -/
def listTodos : Tool :=
  { name := "list_todos"
    description :=
      "List the signed-in person's todos. Returns a JSON array of objects with `id`, `title` " ++
      "and `done`. Call this before any tool that takes an id, since ids come from here."
    schema := schema
      [ ("filter", Json.mkObj
          [ ("type", "string"),
            ("enum", Json.arr #["all", "active", "completed"]),
            ("description", "Which todos to return. Defaults to all.") ]) ]
      [] }

def addTodo : Tool :=
  { name := "add_todo"
    description := "Add a new todo. A title that is blank once trimmed adds nothing."
    schema := schema [("title", stringParam "The text of the new todo.")] ["title"] }

def editTodo : Tool :=
  { name := "edit_todo"
    description :=
      "Change the title of an existing todo. A title that is blank once trimmed deletes it, " ++
      "which is what the same edit through the web interface does."
    schema := schema
      [ ("id", integerParam "The todo's id, as reported by list_todos."),
        ("title", stringParam "The replacement title.") ]
      ["id", "title"] }

def deleteTodo : Tool :=
  { name := "delete_todo"
    description := "Delete a todo outright."
    schema := schema
      [("id", integerParam "The todo's id, as reported by list_todos.")] ["id"] }

/-- Absolute rather than a toggle, so that asking twice for the same thing leaves the same state.
A toggle would make a retried or duplicated call undo the one before it. -/
def setDone : Tool :=
  { name := "set_done"
    description := "Mark a todo done, or put it back to active."
    schema := schema
      [ ("id", integerParam "The todo's id, as reported by list_todos."),
        ("done", Json.mkObj
          [("type", "boolean"), ("description", "True to complete it, false to reactivate it.")]) ]
      ["id", "done"] }

def all : Array Tool := #[listTodos, addTodo, editTodo, deleteTodo, setDone]

/-! ## Running one -/

private def itemJson (item : Item) : Json :=
  Json.mkObj
    [("id", Json.ofInt item.id.toInt), ("title", item.title), ("done", item.completed)]

private def filterOf (input : Json) : Filter :=
  match input.getObjVal? "filter" >>= Json.getStr? with
  | .ok "active" => .active
  | .ok "completed" => .completed
  | _ => .all

private def stringArg (input : Json) (name : String) : Option String :=
  (input.getObjVal? name >>= Json.getStr?).toOption

/-- A model sometimes sends an integer as the string it would print as, so a string that reads as
one is taken. Nothing else is: an id that cannot be read is reported back rather than defaulted
to, since every default would name a real row belonging to somebody. -/
private def idArg (input : Json) (name : String) : Option Int64 :=
  match input.getObjVal? name >>= Json.getInt? with
  | .ok id => some (Int64.ofInt id)
  | .error _ => (stringArg input name).bind (·.toInt?.map Int64.ofInt)

private def boolArg (input : Json) (name : String) : Option Bool :=
  match input.getObjVal? name >>= Json.getBool? with
  | .ok value => some value
  | .error _ =>
    match stringArg input name with
    | some "true" => some true
    | some "false" => some false
    | _ => none

/-- The tool's answer as the model reads it. Every branch says something: a call whose result was
silence would leave the model to assume, and what it assumes is usually that the call worked. -/
private def missing (name : String) : String :=
  s!"error: this call needs a `{name}` argument and did not have a usable one"

/-- Runs one call against the store, as the account that asked for it.

`IO` rather than the store's own `TelemetryT Async` because `LLMClient.converseLoop` fixes the
monad it calls this in. The turn already runs on a thread of its own (see `Todo.ChatTurn`), so
blocking that thread here costs nothing that is not already being waited on; `parent` is what
keeps the spans the store opens underneath the turn's own rather than loose at the root. -/
def run (store : Store) (account : Account) (parent : Option SpanContext)
    (name : String) (input : Json) : IO String :=
  let blocking {α : Type} (act : TelemetryT Async α) : IO α := Async.block (act.run parent)
  match name with
  | "list_todos" => do
    let items ← blocking (store.list account (filterOf input))
    pure (Json.compress (Json.arr (items.map itemJson)))
  | "add_todo" => do
    match stringArg input "title" with
    | none => pure (missing "title")
    | some raw =>
      match normalisedTitle raw with
      | none => pure "error: that title is blank, so nothing was added"
      | some title => blocking (store.add account title); pure s!"added \"{title}\""
  | "edit_todo" => do
    match idArg input "id", stringArg input "title" with
    | none, _ => pure (missing "id")
    | _, none => pure (missing "title")
    | some id, some title =>
      blocking (store.setTitle account id title)
      match normalisedTitle title with
      | none => pure s!"todo {id} had its title cleared, which deleted it"
      | some title => pure s!"todo {id} is now \"{title}\""
  | "delete_todo" => do
    match idArg input "id" with
    | none => pure (missing "id")
    | some id => blocking (store.delete account id); pure s!"deleted todo {id}"
  | "set_done" => do
    match idArg input "id", boolArg input "done" with
    | none, _ => pure (missing "id")
    | _, none => pure (missing "done")
    | some id, some done =>
      blocking (store.setCompleted account id done)
      pure (if done then s!"todo {id} is done" else s!"todo {id} is active again")
  | _ => pure s!"error: there is no tool called `{name}`"

end Todo.ChatTools
