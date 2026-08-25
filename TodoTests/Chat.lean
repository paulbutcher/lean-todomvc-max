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
open Routes
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

/-- One tool as a turn runs it, reached through the registry so that a test cannot exercise an
implementation the model is not offered. -/
private def runTool (store : Store) (name : String) (input : List (String × Json))
    (account : Account := alice) : IO (Except String String) := do
  let some entry := ChatTools.registry.find? (·.tool.name == name)
    | throw (IO.userError s!"there is no tool called {name}")
  Async.block (runTelemetry (entry.run store account (Json.mkObj input)))

private def titlesOf (store : Store) (account : Account := alice) :
    IO (Array (String × Bool)) := do
  let items ← Async.block (runTelemetry (store.list account .all))
  pure (items.map fun item => (item.title, item.completed))

/-- A call is dispatched to the first entry whose name matches, so a second entry sharing a name
could never run, and the model would be offered a tool that does nothing its description says.
Nothing about the registry's shape rules that out.

`Nodup` over the fixed array would say the same thing to the kernel, but only if `Todo.ChatTools`
were `@[expose]`, and that would mean making every argument reader and schema helper in it public
to be reduced through. The array is a constant, so this is checked over the same data either
way. -/
private def testToolNamesAreDistinct : IO Unit := do
  let names := (ChatTools.registry.map (·.tool.name)).toList
  checkEq "every tool has a name of its own" names.length names.eraseDups.length

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
  let .ok listed ← runTool store "list_todos" [("filter", "completed")]
    | throw (IO.userError "list_todos refused a call it should have answered")
  let .ok parsed := Json.parse listed
    | throw (IO.userError s!"list_todos did not return JSON: {listed}")
  let .ok items := parsed.getArr?
    | throw (IO.userError s!"list_todos did not return an array: {listed}")
  checkEq "only the completed one" 1 items.size
  checkEq "carrying the id the other tools take" (some (2 : Int))
    (((items[0]?.getD Json.null).getObjVal? "id" >>= Json.getInt?).toOption)

/-- A call the store cannot be asked to perform is refused and reported, not guessed at. An id
that defaulted to something would name a real row belonging to somebody.

That a refusal is decided before the store is reached is what lets `Todo.ChatTurn` treat one as
having changed nothing, so the two halves are checked together. -/
private def testUnusableCallsChangeNothing : IO Unit := do
  let store ← memoryStore alice #[alpha]
  let noId ← runTool store "delete_todo" [("title", "alpha")]
  checkEq "a missing id is refused" false noId.isOk
  let blank ← runTool store "add_todo" [("title", "   ")]
  checkEq "so is a title that is blank once trimmed" false blank.isOk
  checkEq "and neither of them touched anything" #[("alpha", false)] (← titlesOf store)

/-- A tool runs as the account that asked for it, so an id belonging to somebody else matches
nothing. This is the store's own guarantee; what is checked here is that the tools go through it
rather than around it. -/
private def testToolsCannotReachAnotherAccount : IO Unit := do
  let store ← memoryStore alice #[alpha]
  discard <| runTool store "delete_todo" [("id", Json.ofNat 1)] (account := bob)
  checkEq "alice still has hers" #[("alpha", false)] (← titlesOf store)
  let listed ← runTool store "list_todos" [] (account := bob)
  checkEq "and bob sees none of it" (some "[]") listed.toOption

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
    (Todo.app (fixedIdentity alice (← IO.mkRef 0)) store assistant noGrants)).onRequest

/-- The conversation as a pair per message, since `LLMClient.Msg` has no `Repr` for a failure to
be reported through. What each message is and what it says is the whole of what these check. -/
private def transcriptOf (assistant : Assistant) (account : Account := alice) :
    IO (Array (String × String)) := do
  let history ← Async.block (runTelemetry (assistant.chat.history account))
  pure <| history.map fun
    | .user text => ("user", text)
    | .assistant text _ => ("assistant", text)
    | .toolResult id .. => ("tool", id)

private def sendPrompt (body : String) : String :=
  mkPost "/chat" body
    "Content-Type: application/x-www-form-urlencoded\x0d\nConnection: close\x0d\n"

/-- The prompt is on the page before the model has said anything: the request that carries it
stores it and answers with the transcript it is now in, rather than waiting out the turn. The gate
is what makes "before" a place a test can stand, since it holds the turn open until it is let go.

`whileHeld` then lets it go however the block ends, which is what keeps the scripted provider's
thread from outliving the test even when an assertion inside fails. -/
private def testAPromptIsShownBeforeTheModelReplies : IO Unit := do
  let gate ← IO.Promise.new
  let assistant ← scriptedAssistant #[{ text := "Two todos are left." }] (gate := some gate)
  let store ← memoryStore alice #[alpha]
  let handler ← panelOf assistant store
  whileHeld gate do
    check "POST /chat" (sendPrompt "prompt=what+is+left") handler
      fun response => do
        assertContains response "what is left"
        assertAbsent response "Two todos are left."
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
  whileHeld gate do
    check "the first prompt" (sendPrompt "prompt=one") handler fun _ => pure ()
    check "the second, mid-turn" (sendPrompt "prompt=two") handler fun response =>
      assertAbsent response "two"
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
  whileHeld gate do
    check "a prompt" (sendPrompt "prompt=anything") handler fun response =>
      assertContains response links.chatStatus
  check "GET /chat/status" (mkGetClose "/chat/status") handler fun response => do
    assertContains response "All done."
    assertAbsent response links.chatStatus

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
    assertAbsent response links.chatStatus
  check "the next one" (mkGetClose "/chat/status") handler fun response =>
    assertAbsent response "went wrong"

/-- A turn can fail on the round trip that follows its tool calls, by which point those calls have
already changed the list. The transcript has to say so: a conversation that performed a deletion
and then never mentions it will have the model answering from a history that disagrees with what
the person is looking at.

The script holds one reply, so the tool call is answered and the request carrying its result back
finds nothing left to say and fails. That is the shape of the real failure. -/
private def testAFailedTurnStillRecordsWhatItsToolsDid : IO Unit := do
  let assistant ← scriptedAssistant
    #[{ text := "", toolCalls := #[{ id := "call_1", name := "add_todo",
                                     input := Json.mkObj [("title", "gamma")] }] }]
  let store ← memoryStore alice #[]
  check "a prompt" (sendPrompt "prompt=add+gamma") (← panelOf assistant store) fun _ => pure ()
  awaitTurn assistant.turns alice "the turn that fails after its tool ran"
  checkEq "the tool really did change the list" #[("gamma", false)] (← titlesOf store)
  checkEq "and the transcript says so, closing with a reply the next turn can follow"
    #[("user", "add gamma"), ("assistant", ""), ("tool", "call_1"),
      ("assistant", Todo.unfinishedNote)]
    (← transcriptOf assistant)

/-- What a poll refreshes the list against is a count of the calls that changed it, and a call
that was refused changed nothing. Counting one would swap the list out from under somebody
part-way through editing a todo, for nothing.

Both halves are here because either alone would pass against a count that never moves at all.
Neither script holds a reply after the tool call, so both turns fail, which is what leaves the
count behind to be read: a turn that finished would have erased it. -/
private def testOnlyToolsThatChangedSomethingAreCounted : IO Unit := do
  let calling (title : String) : Array LLMClient.Reply :=
    #[{ text := "", toolCalls := #[{ id := "call_1", name := "add_todo",
                                     input := Json.mkObj [("title", title)] }] }]
  let countAfter (title : String) : IO (Option Nat) := do
    let assistant ← scriptedAssistant (calling title)
    let store ← memoryStore alice #[]
    check "a prompt" (sendPrompt "prompt=add+it") (← panelOf assistant store) fun _ => pure ()
    awaitTurn assistant.turns alice "the turn that fails after its tool ran"
    pure ((← assistant.turns.get alice).map (·.mutations))
  checkEq "a call that added something counts" (some 1) (← countAfter "gamma")
  checkEq "a call the tool refused does not" (some 0) (← countAfter "   ")

/-- The counterpart: a turn that fails before any tool runs has nothing to record, and a note on
its own would be noise in a transcript that already ends on the unanswered prompt. -/
private def testAFailureBeforeAnyToolRecordsNothing : IO Unit := do
  let assistant ← scriptedAssistant #[]
  let store ← memoryStore alice #[]
  check "a prompt" (sendPrompt "prompt=anything") (← panelOf assistant store) fun _ => pure ()
  awaitTurn assistant.turns alice "the turn that fails outright"
  checkEq "the prompt stands alone" #[("user", "anything")] (← transcriptOf assistant)

/-- A tool that changes the list has to reach the list on the page. The poll answers into the chat
panel, so the list rides along as an out-of-band swap; without one the assistant would report an
addition the person cannot see until they reload.

"gamma" is the load-bearing word here: the transcript shows the tool's *name* and the model's
reply, never its argument or its result, so the only way that title can appear in this response is
in a freshly rendered list. -/
private def testAToolChangeReachesTheTodoList : IO Unit := do
  let assistant ← scriptedAssistant
    #[{ text := "", toolCalls := #[{ id := "call_1", name := "add_todo",
                                     input := Json.mkObj [("title", "gamma")] }] },
      { text := "Added it." }]
  let store ← memoryStore alice #[]
  let handler ← panelOf assistant store
  check "a prompt" (sendPrompt "prompt=add+gamma") handler fun _ => pure ()
  awaitTurn assistant.turns alice "the turn that adds"
  check "the poll carrying the reply" (mkGetClose "/chat/status?seen=0") handler
    fun response => do
      assertContains response "Added it."
      assertContains response "gamma"
      assertContains response "hx-swap-oob"

/-- The other half: a poll that has nothing new to report leaves the list alone. Re-swapping it on
every poll would work, and would also throw away a todo the person was part-way through editing,
so a poll says which count it was drawn against and gets a list back only past that.

The gate holds the turn before its first reply, so nothing has run and the count is still nought.
This one costs the poll's full wait, since there is deliberately no movement to cut it short. -/
private def testAPollWithNothingNewLeavesTheListAlone : IO Unit := do
  let gate ← IO.Promise.new
  let assistant ← scriptedAssistant #[{ text := "hello" }] (gate := some gate)
  let store ← memoryStore alice #[alpha]
  let handler ← panelOf assistant store
  whileHeld gate do
    check "a prompt" (sendPrompt "prompt=anything") handler fun _ => pure ()
    check "a poll drawn against the same count" (mkGetClose "/chat/status?seen=0") handler
      fun response => assertAbsent response "hx-swap-oob"
  awaitTurn assistant.turns alice "the gated turn"

def runChatTests : IO Unit := do
  testToolNamesAreDistinct
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
  testAFailedTurnStillRecordsWhatItsToolsDid
  testOnlyToolsThatChangedSomethingAreCounted
  testAFailureBeforeAnyToolRecordsNothing
  testAToolChangeReachesTheTodoList
  testAPollWithNothingNewLeavesTheListAlone
  testResetForgetsTheConversation

end TodoTests
