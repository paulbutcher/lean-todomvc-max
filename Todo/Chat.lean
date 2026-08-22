/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Async.Basic
public import Std.Sync.Mutex
public import Telemetry
public import LLMClient
public import Todo.Tenant

@[expose] public section

open Std.Async (Async)
open Telemetry (TelemetryT)

namespace Todo

open LLMClient (Msg ToolCall)

/-! ## A message as a row -/

/-- `LLMClient.Msg` spread over the columns a table can hold it in. The alternative, one JSON
document per row, would put the discriminator inside a blob and so out of reach of a query.

`toolCalls` is `Json` rather than the text a column stores, so that `toMsg_ofMsg` below holds
outright. Text costs the round trip its unconditionality: what a model sends as a tool's input is
arbitrary JSON, free to nest deeper or carry longer numbers than a reader admits. -/
structure ChatRow where
  role : String
  body : String
  toolCalls : Json
  toolCallId : String

def toolCallJson (call : ToolCall) : Json :=
  Json.mkObj [("id", call.id), ("name", call.name), ("input", call.input)]

/-- An element that is not an object with `id` and `name` was not written by `toolCallJson`, and
there is nothing to call. Dropping it keeps the surrounding transcript readable, which discarding
the whole history would not. -/
def toolCallOfJson (j : Json) : Option ToolCall :=
  match j.getObjVal? "id" >>= Json.getStr?, j.getObjVal? "name" >>= Json.getStr? with
  | .ok id, .ok name =>
    some { id, name, input := (j.getObjVal? "input").toOption.getD (Json.mkObj []) }
  | _, _ => none

def toolCallsJson (calls : Array ToolCall) : Json := Json.arr (calls.map toolCallJson)

def toolCallsOfJson (j : Json) : Array ToolCall :=
  match j.getArr? with
  | .ok elems => elems.filterMap toolCallOfJson
  | .error _ => #[]

def ChatRow.ofMsg : Msg → ChatRow
  | .user text => { role := "user", body := text, toolCalls := Json.arr #[], toolCallId := "" }
  | .assistant text calls =>
    { role := "assistant", body := text, toolCalls := toolCallsJson calls, toolCallId := "" }
  | .toolResult id output =>
    { role := "tool", body := output, toolCalls := Json.arr #[], toolCallId := id }

/-- A role outside the three `ofMsg` writes is read as a user turn. Refusing it instead would
make one unrecognised row hide the whole conversation behind it. -/
def ChatRow.toMsg (row : ChatRow) : Msg :=
  if row.role == "assistant" then .assistant row.body (toolCallsOfJson row.toolCalls)
  else if row.role == "tool" then .toolResult row.toolCallId row.body
  else .user row.body

/-! ## Storage -/

/-- The conversation, kept where the todos are rather than in the session: the deployed function
seals its session into a cookie, and a transcript outgrows what a browser will carry long before
it stops being worth reading.

`append` takes an array because a turn produces several messages at once (what the model said,
and a result for each tool it called) and they are only meaningful in order. -/
structure ChatStore where
  history : Account → TelemetryT Async (Array Msg)
  append : Account → Array Msg → TelemetryT Async Unit
  clear : Account → TelemetryT Async Unit

/-! ## What a turn in flight is doing -/

/-- Where a turn has got to, as the panel reports it while the model works. -/
inductive TurnPhase where
  | thinking
  | callingTool (name : String)
  | failed (message : String)
deriving Inhabited, BEq, Repr

/-- `tools` accumulates every tool the turn has called so far, in order, so the panel can show
the whole sequence rather than only whichever call is in flight.

`mutations` counts the calls among them that changed the list, so that a poll can tell whether
the list on the page is still what the store holds. A count rather than a flag because a poll
reports which value it last saw: it is how the refresh happens once per change instead of once
per poll, and re-swapping a list unprompted would discard a todo the person was part-way through
editing. -/
structure TurnState where
  phase : TurnPhase
  tools : Array String := #[]
  mutations : Nat := 0
deriving Inhabited

/-- The turns running right now, keyed by the account that asked for one. Absent means no turn is
in flight, which is also how a finished one reports itself: the runner removes its entry after
writing what the model said, so the next poll reads the transcript and stops polling.

A mutex rather than an `IO.Ref` because the runner writes from its own thread while the request
serving the poll reads, and `IO.Ref.modify` is not atomic against that.

In memory, so it does not survive a restart and is not shared between instances. A turn is worth
no more than the process running it: the transcript is what persists, and a turn whose process
went has nothing left to report. -/
structure Turns where
  state : Std.Mutex (Std.HashMap String TurnState)

def Turns.new : IO Turns := do pure { state := ← Std.Mutex.new ∅ }

def TurnPhase.isRunning : TurnPhase → Bool
  | .failed _ => false
  | _ => true

def Turns.get (turns : Turns) (account : Account) : IO (Option TurnState) :=
  turns.state.atomically do pure ((← MonadState.get).get? account.value)

def Turns.finish (turns : Turns) (account : Account) : IO Unit :=
  turns.state.atomically do modify (·.erase account.value)

/-- Reports a turn that never got an answer. The entry stays behind rather than being erased,
because a poll that found nothing would read it as a turn that finished and go looking in the
transcript for a reply that was never written. Whoever reads the failure erases it. -/
def Turns.fail (turns : Turns) (account : Account) (message : String) : IO Unit :=
  turns.state.atomically do
    modify fun states =>
      let previous := states.get? account.value
      states.insert account.value
        { phase := .failed message,
          tools := (previous.map (·.tools)).getD #[],
          mutations := (previous.map (·.mutations)).getD 0 }

/-- Moves a running turn on. Absent means the turn is over, and a progress report that arrives
after that is dropped rather than resurrecting the entry. -/
def Turns.advance (turns : Turns) (account : Account) (f : TurnState → TurnState) : IO Unit :=
  turns.state.atomically do
    modify fun states =>
      match states.get? account.value with
      | some state => states.insert account.value (f state)
      | none => states

/-- Whether a turn may start, claiming the slot in the same atomic step if it may. Two requests
arriving together would otherwise both find nothing running and start a turn each, and the two
would interleave their writes into one transcript.

A failure left for a reader that never came does not hold the next turn up: it is what a reload
rather than a poll leaves behind, and it has already been reported to nobody. -/
def Turns.claim (turns : Turns) (account : Account) : IO Bool :=
  turns.state.atomically do
    let running := ((← MonadState.get).get? account.value).any (·.phase.isRunning)
    if running then
      pure false
    else
      modify (·.insert account.value { phase := .thinking })
      pure true

end Todo
