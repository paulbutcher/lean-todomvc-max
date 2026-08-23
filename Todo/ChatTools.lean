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

/-! ## Describing one -/

private def stringParam (description : String) : Json :=
  Json.mkObj [("type", "string"), ("description", description)]

private def integerParam (description : String) : Json :=
  Json.mkObj [("type", "integer"), ("description", description)]

private def schema (properties : List (String × Json)) (required : List String) : Json :=
  Json.mkObj
    [ ("type", "object"),
      ("properties", Json.mkObj properties),
      ("required", Json.arr (required.map (Json.str ·)).toArray) ]

/-! ## Reading what the model sent -/

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

private def missing (name : String) : Except String String :=
  .error s!"this call needs a `{name}` argument and did not have a usable one"

/-- `IO` rather than the store's own `TelemetryT Async` because `LLMClient.ToolImpl` fixes the
monad a tool runs in. The turn already runs on a thread of its own (see `Todo.ChatTurn`), so
blocking that thread here costs nothing that is not already being waited on; `parent` is what
keeps the spans the store opens underneath the turn's own rather than loose at the root. -/
private def blocking {α : Type} (parent : Option SpanContext) (act : TelemetryT Async α) : IO α :=
  Async.block (act.run parent)

/-! ## The tools -/

/-- One tool: what the model is offered, what running it does, and whether a call can leave the
list different from how it found it.

`mutates` is what decides whether the page showing that list has gone stale, and it is a field
rather than a judgement made about a name elsewhere, so a tool cannot be added without answering
the question.

`run` reports a call it could not carry out as `.error`, which reaches the model as a result
flagged as one. Every such refusal here is decided before the store is touched, so an `.error`
also means nothing changed; `Todo.ChatTurn` counts mutations on that basis. -/
structure Entry where
  tool : Tool
  mutates : Bool
  run : Store → Account → Option SpanContext → Json → IO (Except String String)

/-- The id in every schema below is the one `list_todos` reports, and the descriptions say so.
A model that has not listed yet has no id it could have invented, which is what keeps it from
guessing at one; an id it guesses anyway belongs to somebody else's list or to nothing, and the
store's own account filter makes both a no-op rather than a stranger's item. -/
def listTodos : Entry where
  tool :=
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
  mutates := false
  run store account parent input := do
    let items ← blocking parent (store.list account (filterOf input))
    pure (.ok (Json.compress (Json.arr (items.map itemJson))))

def addTodo : Entry where
  tool :=
    { name := "add_todo"
      description := "Add a new todo. A title that is blank once trimmed adds nothing."
      schema := schema [("title", stringParam "The text of the new todo.")] ["title"] }
  mutates := true
  run store account parent input := do
    match stringArg input "title" with
    | none => pure (missing "title")
    | some raw =>
      match normalisedTitle raw with
      | none => pure (.error "that title is blank, so nothing was added")
      | some title => blocking parent (store.add account title); pure (.ok s!"added \"{title}\"")

def editTodo : Entry where
  tool :=
    { name := "edit_todo"
      description :=
        "Change the title of an existing todo. A title that is blank once trimmed deletes it, " ++
        "which is what the same edit through the web interface does."
      schema := schema
        [ ("id", integerParam "The todo's id, as reported by list_todos."),
          ("title", stringParam "The replacement title.") ]
        ["id", "title"] }
  mutates := true
  run store account parent input := do
    match idArg input "id", stringArg input "title" with
    | none, _ => pure (missing "id")
    | _, none => pure (missing "title")
    | some id, some title =>
      blocking parent (store.setTitle account id title)
      match normalisedTitle title with
      | none => pure (.ok s!"todo {id} had its title cleared, which deleted it")
      | some title => pure (.ok s!"todo {id} is now \"{title}\"")

def deleteTodo : Entry where
  tool :=
    { name := "delete_todo"
      description := "Delete a todo outright."
      schema := schema
        [("id", integerParam "The todo's id, as reported by list_todos.")] ["id"] }
  mutates := true
  run store account parent input := do
    match idArg input "id" with
    | none => pure (missing "id")
    | some id => blocking parent (store.delete account id); pure (.ok s!"deleted todo {id}")

/-- Absolute rather than a toggle, so that asking twice for the same thing leaves the same state.
A toggle would make a retried or duplicated call undo the one before it. -/
def setDone : Entry where
  tool :=
    { name := "set_done"
      description := "Mark a todo done, or put it back to active."
      schema := schema
        [ ("id", integerParam "The todo's id, as reported by list_todos."),
          ("done", Json.mkObj
            [("type", "boolean"),
             ("description", "True to complete it, false to reactivate it.")]) ]
        ["id", "done"] }
  mutates := true
  run store account parent input := do
    match idArg input "id", boolArg input "done" with
    | none, _ => pure (missing "id")
    | _, none => pure (missing "done")
    | some id, some done =>
      blocking parent (store.setCompleted account id done)
      pure (.ok (if done then s!"todo {id} is done" else s!"todo {id} is active again"))

def registry : Array Entry := #[listTodos, addTodo, editTodo, deleteTodo, setDone]

end Todo.ChatTools
