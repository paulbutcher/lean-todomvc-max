/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Htmx
public import GFMarkdown
public import Todo.Chat
public import Todo.Links

@[expose] public section

namespace Todo

open Html
open Routes
open LLMClient (Msg)

/-- What a model writes is Markdown, and it is not trusted to be only that: `renderHtmlSafe`
drops embedded HTML and refuses a link scheme outside its allowlist, which is what stands between
a reply and script running on the page it is rendered into.

GFM rather than plain CommonMark for the tables and task lists a model reaches for unprompted
when it is asked to lay something out. -/
def renderMarkdown (text : String) : Node .flow :=
  Node.unsafeRaw (GFMarkdown.renderHtmlSafe (GFMarkdown.parseDocument text))

/-- One tool call as the panel names it. The model's own names are what appear, since they are
what it is asked to call and what a reader comparing the two would look for. -/
def toolLine (running : Bool) (name : String) : Node .listItem :=
  li [(span [name] { class_ := "chat-tool-name" } : Node .flow)]
    { class_ := if running then "chat-tool running" else "chat-tool" }

def toolList (tools : Array String) (runningLast : Bool) : List (Node .flow) :=
  if tools.isEmpty then []
  else
    [(ul (tools.toList.zipIdx.map fun (name, index) =>
        toolLine (runningLast && index + 1 == tools.size) name)
       { class_ := "chat-tools" } : Node .flow)]

/-! ## The transcript -/

/-- A message the person is meant to read. A tool result is not one: it exists so the model can
answer, and showing it would put the raw JSON of every lookup in the middle of the conversation.
What the model *asked for* is shown instead, by `messageView` below.

An assistant turn with no text is one that only called tools, and the turn it belongs to has
another message coming with the answer in it. -/
def messageView : Msg → List (Node .flow)
  | .user text =>
    [div [div [text] { class_ := "chat-bubble" }] { class_ := "chat-message from-user" }]
  | .assistant text calls =>
    let spoken :=
      if text.isEmpty then []
      else [(div [renderMarkdown text] { class_ := "chat-bubble" } : Node .flow)]
    let asked := toolList (calls.map (·.name)) (runningLast := false)
    if spoken.isEmpty && asked.isEmpty then []
    else [div (asked ++ spoken) { class_ := "chat-message from-assistant" }]
  | .toolResult _ _ => []

/-- What the model is doing right now, which the transcript cannot show because none of it has
been said yet. Absent once the turn is over, and that absence is also what stops the polling:
the fragment this sits in carries the trigger for the next poll only while there is one. -/
def turnView : TurnState → Node .flow
  | { phase := .failed message, tools, .. } =>
    div (toolList tools (runningLast := false) ++
        [(div [s!"That went wrong: {message}"] { class_ := "chat-bubble chat-error" } :
            Node .flow)])
      { class_ := "chat-message from-assistant" }
  | { phase := .callingTool _, tools, .. } =>
    div (toolList tools (runningLast := true)) { class_ := "chat-message from-assistant" }
  | { phase := .thinking, tools, .. } =>
    div (toolList tools (runningLast := false) ++
        [(div [span ["Thinking"] {}] { class_ := "chat-bubble chat-thinking" } : Node .flow)])
      { class_ := "chat-message from-assistant" }

def emptyTranscript : Node .flow :=
  div [p ["Ask me to add, change, or find something in your list."]] { class_ := "chat-empty" }

/-- The polled part of the panel, and the whole of what a poll returns.

A turn in flight puts the trigger for the next poll on this element, and finishing simply omits
it: the swap that carries the model's reply is the same swap that stops the asking, so there is
no separate signal to miss. `load` rather than `every` for the same reason, since each fragment
re-arms exactly once and a fragment that does not re-arm is the end of it. -/
def conversationView (messages : Array Msg) (turn : Option TurnState) : Node .flow :=
  let body :=
    if messages.isEmpty && turn.isNone then [emptyTranscript]
    else (messages.toList.flatMap messageView) ++ (turn.map turnView).toList
  let polling := turn.any (·.phase.isRunning)
  -- The next poll carries how many mutations this fragment was rendered against, which is what
  -- lets the handler answer "has the list changed since you last saw it" without keeping any
  -- per-browser state of its own.
  let seen := (turn.map (·.mutations)).getD 0
  Htmx.div body
    { id := "chat-conversation", class_ := "chat-conversation"
      hxGet := if polling then some s!"{links.chatStatus}?seen={seen}" else none
      hxTrigger := if polling then some "load delay:200ms" else none
      hxTarget := if polling then some "this" else none
      hxSwap := if polling then some .outerHTML else none }

/-! ## The panel -/

/-- Reading a transcript is reading the end of it, so the browser is asked to put the newest
message in view whenever this is swapped, which is what `chat.js` listens for. -/
def chatPanel (messages : Array Msg) (turn : Option TurnState) : Node .flow :=
  aside
    [ div
        [ (h2 ["Assistant"] : Node .flow),
          (Htmx.button ["New chat"]
            { class_ := "chat-reset", hxDelete := links.chat,
              hxTarget := "#chat-conversation", hxSwap := some .outerHTML,
              hxConfirm := "Start a new conversation? This one will be forgotten." } :
            Node .flow) ]
        { class_ := "chat-header" },
      conversationView messages turn,
      Htmx.form
        [ Htmx.textarea ""
            { name := "prompt", class_ := "chat-prompt", rows := some "2",
              placeholder := "Ask about your todos" },
          (Htmx.button ["Send"] { class_ := "chat-send" } : Node .flow) ]
        { class_ := "chat-form", hxPost := links.chat, hxTarget := "#chat-conversation",
          hxSwap := some .outerHTML, hxOnHtmx := [("after-request", "this.reset()")] } ]
    { id := "chat-panel", class_ := "chat-panel" }

end Todo
