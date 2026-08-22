/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import LLMClient
public import Todo.Chat
public import Todo.ChatTools

public section

open Std.Async (Async)
open Telemetry

namespace Todo

open LLMClient (Msg Provider)
open LLMClient.Bedrock (defaultConfig)

/-- Everything the panel needs that is not the todo store: where to send a conversation, where to
keep it, and what is in flight right now.

`provider` is an action rather than a `Provider` because Bedrock signs with credentials that
expire, and the deployed function is handed fresh ones in its environment rather than being
restarted. Building it per turn is the same reasoning as `Todo.Auth.refreshing`; holding one
built at startup is the mistake that works all day and then stops. -/
structure Assistant where
  provider : IO Provider
  chat : ChatStore
  turns : Turns

/-- What the model is told it is before a word of the conversation. It has no way to see the page
the person is looking at, so the list has to be asked for rather than assumed, and saying so is
what stops it answering "what's left?" out of a transcript that has gone stale. -/
def systemPrompt : String :=
  "You are the assistant built into a todo list application, talking to the person whose list " ++
  "it is. Use the tools to read and change their todos rather than answering from memory: the " ++
  "list changes underneath you, both from your own tool calls and from the person editing it " ++
  "directly, so call list_todos again rather than trusting what it said earlier in this " ++
  "conversation. Ids are internal; refer to a todo by its title when you talk about it. Keep " ++
  "replies short. Format them as Markdown, and use a bulleted list when you are listing todos."

def maxOutputTokens : Nat := 1024

/-- How many times the model may call tools and be asked again within one turn. Six covers the
listing-then-changing-then-listing-again that most requests come to; a request that genuinely
needs more is reported as such by `converseLoop` rather than run on indefinitely. -/
def maxIterations : Nat := 6

/-- The Bedrock provider, built afresh from whatever `fresh` reports at the moment of asking.
Both deployments pass an action that reads the environment rather than a value read at start-up,
because an execution role's credentials are rotated underneath a running process.

`BEDROCK_MODEL` names the model, and defaults to whatever `LLMClient` considers current. Which
models an account may call, and under which id, differs by region and by what has been enabled
in it, so this is not something the application can settle for itself. -/
def bedrockProvider (fresh : IO Aws.Sigv4.Credentials) (region : String) : IO Provider := do
  let defaults := defaultConfig region
  -- An empty variable is an unset one: the deployment template always sets it, and its default
  -- is the empty string.
  let model := ((← IO.getEnv "BEDROCK_MODEL").filter (!·.isEmpty)).getD defaults.model
  pure (LLMClient.Bedrock.provider (← fresh)
    { defaults with model, maxOutputTokens, systemPrompt := some systemPrompt })

/-- What is written in place of the reply a failed turn never produced.

Not an apology: it is there so the conversation can be replayed at all. A history left ending on
tool results ends mid-exchange, and both APIs behind `LLMClient` require roles to alternate, so
the next prompt would sit against it as a second user turn and be refused. -/
def unfinishedNote : String :=
  "(This turn stopped before I could reply. Any tools listed above did run.)"

/-- Stores whatever a failed turn got through before it failed, and closes it off.

`stored` is what was already in the transcript and `reached` is what `converseLoop` had
accumulated when it gave up; only the difference is new. Nothing is written when they are the
same length, which is a turn that failed on its first request with no tool having run: there is
no reply to explain the absence of, and a note on its own would be noise. -/
def recordUnfinished (assistant : Assistant) (account : Account) (parent : Option SpanContext)
    (stored reached : Array Msg) : IO Unit := do
  if reached.size > stored.size then
    let added := (reached.extract stored.size reached.size).push (.assistant unfinishedNote)
    Async.block ((assistant.chat.append account added).run parent)

/-- Runs one turn to completion and records what came of it, having been started by a request
that has already answered and gone.

The user's message is expected to be in the transcript already: the request that started this
wrote it there before returning, which is what lets the panel show it without waiting for any of
what happens here.

Nothing is returned, because there is nobody left to return it to. What the model said goes to
`chat`, where the next poll reads it; a failure goes to `turns`, which is the only place a poll
would otherwise see a turn that simply stopped. -/
def runTurn (assistant : Assistant) (store : Store) (account : Account) :
    TelemetryT IO Unit :=
  spanning "chat turn" do
    -- The turn's own span, not the request's: everything below outlives the request, and the
    -- tools reach `ChatTools.run` through `converseLoop`, which fixes `IO` and so has nowhere
    -- for a context to travel implicitly.
    let parent ← currentSpan
    try
      let history ← Async.block ((assistant.chat.history account).run parent)
      let provider ← assistant.provider
      let onProgress : LLMClient.Progress → IO Unit
        | .thinking => assistant.turns.advance account ({ · with phase := .thinking })
        | .runningTool name =>
          assistant.turns.advance account fun state =>
            { state with phase := .callingTool name, tools := state.tools.push name }
      let result ← LLMClient.converseLoop provider ChatTools.all
        (ChatTools.run store account parent) history
        { maxIterations, onProgress }
      match result with
      | .error failure =>
        -- A turn can fail after its tools have run, and those calls have already changed the
        -- list. Storing what happened is what keeps the transcript honest about it; the
        -- alternative is a conversation that never mentions the deletion it performed.
        recordUnfinished assistant account parent history failure.history
        assistant.turns.fail account failure.message
      | .ok (updated, _) =>
        -- Everything `converseLoop` added: what the model said, and a result per tool it called.
        -- The prefix is the history it was handed, which is already stored.
        Async.block
          ((assistant.chat.append account (updated.extract history.size updated.size)).run parent)
        assistant.turns.finish account
    catch error =>
      assistant.turns.fail account (toString error)

/-- Starts a turn on a thread of its own and returns without waiting for it.

Every step of a turn blocks: `converseLoop` waits on the model over libcurl for as long as it
takes to answer, and the store operations its tools reach for are the same blocking calls a
request handler makes. Running that on the fiber serving the request would hold the thread that
fiber shares with every other request in flight, for the tens of seconds an answer can take.

Retaining nothing of the task is deliberate: `runTurn` reports where it got to through `turns`
and `chat`, and there is no result here worth waiting on. -/
def startTurn (assistant : Assistant) (store : Store) (account : Account)
    (parent : Option SpanContext) : IO Unit := do
  let _ ← IO.asTask ((runTurn assistant store account).run parent) Task.Priority.dedicated

end Todo
