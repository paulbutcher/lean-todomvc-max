/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.App
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Html (Node)
open Std.Async (Async)
open Std.Http.Internal.Test
open Telemetry (runTelemetry)
open LLMClient (Msg ToolCall)

theorem toolCallOfJson_toolCallJson (call : ToolCall) :
    toolCallOfJson (toolCallJson call) = some call := rfl

theorem toolCallsOfJson_toolCallsJson (calls : Array ToolCall) :
    toolCallsOfJson (toolCallsJson calls) = calls := by
  show (calls.map toolCallJson).filterMap toolCallOfJson = calls
  rw [Array.filterMap_map]
  simp [Function.comp_def, toolCallOfJson_toolCallJson]

/-- What is written to a row is what is read back from it. A conversation is replayed to the
model in full on every turn, so a message that comes back altered is not a display fault: it
changes what the model is answering. -/
theorem toMsg_ofMsg (msg : Msg) : (ChatRow.ofMsg msg).toMsg = msg := by
  cases msg <;> simp [ChatRow.ofMsg, ChatRow.toMsg, toolCallsOfJson_toolCallsJson]

/-! ## The tools -/

private def alpha : Item := { id := 1, title := "alpha", completed := false }
private def beta : Item := { id := 2, title := "beta", completed := true }

private def runTool (store : Store) (name : String) (input : List (String × Json)) : IO String :=
  ChatTools.run store alice none name (Json.mkObj input)

private def titlesOf (store : Store) (account : Account := alice) :
    IO (Array (String × Bool)) := do
  let items ← Async.block (runTelemetry (store.list account .all))
  pure (items.map fun item => (item.title, item.completed))

/-- Every tool the model is offered reaches the store as its description says it does. A tool that
silently did nothing is the failure that a model cannot report and a reader cannot see: the reply
still says the todo was added. -/
private def testEachToolChangesTheStore : IO Unit := do
  let store ← memoryStore alice #[alpha, beta]
  discard <| runTool store "add_todo" [("title", "gamma")]
  checkEq "add_todo added it" #[("alpha", false), ("beta", true), ("gamma", false)]
    (← titlesOf store)
  discard <| runTool store "set_done" [("id", Json.ofNat 1), ("done", true)]
  checkEq "set_done completed it" #[("alpha", true), ("beta", true), ("gamma", false)]
    (← titlesOf store)
  discard <| runTool store "set_done" [("id", Json.ofNat 1), ("done", false)]
  checkEq "set_done reactivated it" #[("alpha", false), ("beta", true), ("gamma", false)]
    (← titlesOf store)
  discard <| runTool store "edit_todo" [("id", Json.ofNat 2), ("title", "renamed")]
  checkEq "edit_todo retitled it" #[("alpha", false), ("renamed", true), ("gamma", false)]
    (← titlesOf store)
  discard <| runTool store "delete_todo" [("id", Json.ofNat 2)]
  checkEq "delete_todo removed it" #[("alpha", false), ("gamma", false)] (← titlesOf store)

/-- `set_done` says what state the todo ends in rather than flipping it, so a model that repeats
a call (or is retried after one it never saw the answer to) leaves the same state behind. A
toggle would undo the work of the call before it. -/
private def testSetDoneIsIdempotent : IO Unit := do
  let store ← memoryStore alice #[alpha]
  for _ in [0:3] do
    discard <| runTool store "set_done" [("id", Json.ofNat 1), ("done", true)]
  checkEq "three identical calls, one result" #[("alpha", true)] (← titlesOf store)

/-- `list_todos` reports the ids every other tool is documented to take, so what it returns has
to be readable as JSON rather than as prose. -/
private def testListTodosReportsIdsAsJson : IO Unit := do
  let store ← memoryStore alice #[alpha, beta]
  let listed ← runTool store "list_todos" [("filter", "completed")]
  let .ok parsed := Json.parse listed
    | throw (IO.userError s!"list_todos did not return JSON: {listed}")
  let .ok items := parsed.getArr?
    | throw (IO.userError s!"list_todos did not return an array: {listed}")
  checkEq "only the completed one" 1 items.size
  checkEq "carrying the id the other tools take" (some (2 : Int))
    (((items[0]?.getD Json.null).getObjVal? "id" >>= Json.getInt?).toOption)

/-- A call the store cannot be asked to perform is refused and reported, not guessed at. An id
that defaulted to something would name a real row belonging to somebody. -/
private def testUnusableCallsChangeNothing : IO Unit := do
  let store ← memoryStore alice #[alpha]
  let noId ← runTool store "delete_todo" [("title", "alpha")]
  checkEq "a missing id is reported" true (noId.startsWith "error")
  let unknown ← runTool store "reticulate_splines" []
  checkEq "so is a tool that does not exist" true (unknown.startsWith "error")
  checkEq "and neither of them touched anything" #[("alpha", false)] (← titlesOf store)

/-- A tool runs as the account that asked for it, so an id belonging to somebody else matches
nothing. This is the store's own guarantee; what is checked here is that the tools go through it
rather than around it. -/
private def testToolsCannotReachAnotherAccount : IO Unit := do
  let store ← memoryStore alice #[alpha]
  let asBob := ChatTools.run store bob none
  discard <| asBob "delete_todo" (Json.mkObj [("id", Json.ofNat 1)])
  checkEq "alice still has hers" #[("alpha", false)] (← titlesOf store)
  let listed ← asBob "list_todos" (Json.mkObj [])
  checkEq "and bob sees none of it" "[]" listed

/-! ## Turns -/

/-- One turn per account at a time, and a failure nobody read does not become a turn that can
never be started again. -/
private def testTurnsAdmitOneAtATime : IO Unit := do
  let turns ← Turns.new
  checkEq "the first claim takes it" true (← turns.claim alice)
  checkEq "the second finds it taken" false (← turns.claim alice)
  checkEq "another account is unaffected" true (← turns.claim bob)
  turns.fail alice "the model was unreachable"
  checkEq "a failure is still there to be read"
    (some (TurnPhase.failed "the model was unreachable")) ((← turns.get alice).map (·.phase))
  checkEq "but does not hold the next turn up" true (← turns.claim alice)

/-! ## Rendering -/

private def contains (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

/-- A model's reply is Markdown from somewhere this application does not control, and it is
rendered into the page. Whatever it contains, what comes out carries no markup of its own. -/
private def testAssistantMarkdownCannotInjectMarkup : IO Unit := do
  let hostile :=
    "<script>alert(1)</script>\n\n[click](javascript:alert(1))\n\n<img src=x onerror=alert(1)>"
  let rendered := Node.render (renderMarkdown hostile)
  checkEq "no script element survives" false (contains rendered "<script")
  checkEq "nor an inline event handler" false (contains rendered "onerror")
  checkEq "nor a javascript: destination" false (contains rendered "javascript:")

/-! ## The panel's routes -/

/-- The routes under `params`, and nothing else. A prompt arrives as a form field, so the routes
alone cannot read one; the rest of the stack `Todo.server` wraps them in is not what is being
checked here, and the `antiForgery` in it would refuse a post carrying no token. -/
private def panelOf (assistant : Assistant) (store : Store) : IO TestHandler := do
  pure (Middleware.apply [Middleware.params]
    (Todo.app (fixedIdentity alice (← IO.mkRef 0)) store assistant)).onRequest

/-- The conversation as a pair per message, since `LLMClient.Msg` has no `Repr` for a failure to
be reported through. What each message is and what it says is the whole of what these check. -/
private def transcriptOf (assistant : Assistant) (account : Account := alice) :
    IO (Array (String × String)) := do
  let history ← Async.block (runTelemetry (assistant.chat.history account))
  pure <| history.map fun
    | .user text => ("user", text)
    | .assistant text _ => ("assistant", text)
    | .toolResult id _ => ("tool", id)

private def sendPrompt (body : String) : String :=
  mkPost "/chat" body
    "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n"

/-- The prompt is on the page before the model has said anything: the request that carries it
stores it and answers with the transcript it is now in, rather than waiting out the turn. The gate
is what makes "before" a place a test can stand, since it holds the turn open until it is let go.

The turn is then let go and awaited, which is also what keeps the scripted provider's thread from
outliving the test. -/
private def testAPromptIsShownBeforeTheModelReplies : IO Unit := do
  let gate ← IO.Promise.new
  let assistant ← scriptedAssistant #[{ text := "Two todos are left." }] (gate := some gate)
  let store ← memoryStore alice #[alpha]
  check "POST /chat" (sendPrompt "prompt=what+is+left") (← panelOf assistant store)
    fun response => do
      assertContains response "what is left"
      assertAbsent response "Two todos are left."
  gate.resolve ()
  awaitTurn assistant.turns alice "the scripted turn"
  checkEq "the prompt and the reply, in that order"
    #[("user", "what is left"), ("assistant", "Two todos are left.")] (← transcriptOf assistant)

/-- A prompt sent while a turn is running is refused rather than stored, since storing it would
put a question into the transcript that nothing is going to answer. -/
private def testASecondPromptDuringATurnIsDropped : IO Unit := do
  let gate ← IO.Promise.new
  let assistant ← scriptedAssistant #[{ text := "first" }, { text := "second" }]
    (gate := some gate)
  let store ← memoryStore alice #[]
  let handler ← panelOf assistant store
  check "the first prompt" (sendPrompt "prompt=one") handler fun _ => pure ()
  check "the second, mid-turn" (sendPrompt "prompt=two") handler fun response =>
    assertAbsent response "two"
  gate.resolve ()
  awaitTurn assistant.turns alice "the first turn"
  checkEq "only the first was ever stored" #[("user", "one"), ("assistant", "first")]
    (← transcriptOf assistant)

/-- A blank prompt is not a question, so nothing is stored and no turn is started. Without this a
stray Enter would spend a model call on an empty string. -/
private def testABlankPromptStartsNothing : IO Unit := do
  let assistant ← scriptedAssistant #[]
  let store ← memoryStore alice #[]
  check "POST /chat with only spaces" (sendPrompt "prompt=+++") (← panelOf assistant store)
    fun _ => pure ()
  checkEq "nothing was stored" 0 (← transcriptOf assistant).size
  checkEq "and no turn was started" none (((← assistant.turns.get alice)).map (·.phase))

/-- Clearing forgets the conversation, so the next prompt is not answered against it. -/
private def testResetForgetsTheConversation : IO Unit := do
  let assistant ← scriptedAssistant #[{ text := "hello" }]
  let store ← memoryStore alice #[]
  let handler ← panelOf assistant store
  check "a prompt" (sendPrompt "prompt=hello+there") handler fun _ => pure ()
  awaitTurn assistant.turns alice "the scripted turn"
  check "DELETE /chat"
    "DELETE /chat HTTP/1.1\x0d\nHost: example.com\x0d\nConnection: close\x0d\n\x0d\n" handler
    fun response => assertAbsent response "hello there"
  checkEq "the transcript is empty" 0 (← transcriptOf assistant).size

/-- The swap that carries the reply is the same swap that stops the asking. Nothing else tells the
panel a turn is over, so a fragment that arrived with the reply and kept its trigger would poll
for ever, and one that dropped the trigger early would leave the reply unfetched. -/
private def testAFinishedTurnStopsThePolling : IO Unit := do
  let gate ← IO.Promise.new
  let assistant ← scriptedAssistant #[{ text := "All done." }] (gate := some gate)
  let store ← memoryStore alice #[]
  let handler ← panelOf assistant store
  check "a prompt" (sendPrompt "prompt=anything") handler fun response =>
    assertContains response "hx-trigger"
  gate.resolve ()
  check "GET /chat/status" (mkGetClose "/chat/status") handler fun response => do
    assertContains response "All done."
    assertAbsent response "hx-trigger"

/-- A turn that never got an answer says so, once. The failure is not in the transcript (nothing
was said to record), so it lives until a poll reads it; a poll that left it there would report the
same failure against every turn after it. -/
private def testAFailedTurnIsReportedOnce : IO Unit := do
  -- No replies scripted, so the provider refuses and `converseLoop` returns the error.
  let assistant ← scriptedAssistant #[]
  let store ← memoryStore alice #[]
  let handler ← panelOf assistant store
  check "a prompt" (sendPrompt "prompt=anything") handler fun _ => pure ()
  awaitTurn assistant.turns alice "the failing turn"
  check "the poll that reads the failure" (mkGetClose "/chat/status") handler fun response => do
    assertContains response "went wrong"
    assertAbsent response "hx-trigger"
  check "the next one" (mkGetClose "/chat/status") handler fun response =>
    assertAbsent response "went wrong"

def runChatTests : IO Unit := do
  testEachToolChangesTheStore
  testSetDoneIsIdempotent
  testListTodosReportsIdsAsJson
  testUnusableCallsChangeNothing
  testToolsCannotReachAnotherAccount
  testTurnsAdmitOneAtATime
  testAssistantMarkdownCannotInjectMarkup
  testAPromptIsShownBeforeTheModelReplies
  testASecondPromptDuringATurnIsDropped
  testABlankPromptStartsNothing
  testAFinishedTurnStopsThePolling
  testAFailedTurnIsReportedOnce
  testResetForgetsTheConversation

end TodoTests
