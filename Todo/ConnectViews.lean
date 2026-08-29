/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Todo.Authorization
public import Todo.Views

public section

open Html
open Routes

namespace Todo

/-- What somebody pastes into their own assistant.

Written to the assistant rather than to the person, because the assistant is what reads it, and
every line of it is doing work. It says to look the answer up rather than recall it, because a
model's picture of its own settings comes from its training data and is stale by the time it
ships; the clients this is aimed at can search, and that is the whole reason this can be one
piece of text rather than one per client. It says what to do when the answer is no, because a
model asked for help will otherwise invent a menu that does not exist. And it ends by calling a
tool, because that is the only check either side can make that the thing actually worked. -/
def agentPrompt (endpoint : String) : String :=
  "I'd like to connect you to my todo list so you can read and update it for me.\n\
   \n\
   It is an MCP server at " ++ endpoint ++ ". It uses OAuth, so you will send me to a \
   browser to sign in and approve access. There is no API key or token to paste.\n\
   \n\
   Before you tell me what to do, please look up your own current documentation for adding a \
   custom MCP server or connector. What you remember about your own settings may be out of \
   date, so go by what you find rather than what you recall.\n\
   \n\
   Then take me through it one step at a time, and ask me which plan I am on if that changes \
   the answer. If you cannot add MCP servers at all, or it needs a plan I might not have, say \
   so plainly rather than suggesting a way around it.\n\
   \n\
   Once it is connected, call list_todos and tell me what you see, so we both know it worked."

private def scopeLine (scope : Authentication.OAuth.Scope) : Node .listItem :=
  li [Todo.Authorization.describe scope]

/-- Withdrawing every approval at once, which is the only shape this can take until an account's
live connections can be listed: there is no way here to name one and leave the rest.

Blunt as it is, it is what somebody stuck actually needs. An assistant that was approved and then
stops working holds something only this server can take away, and until it is gone the assistant
keeps presenting it rather than asking again. -/
private def disconnectSection (token : Option String) : Node .flow :=
  div
    [ Html.label ["If an assistant stops working"],
      p ["An assistant that was approved once and now cannot see your list is holding an \
          approval that no longer works, and nothing it does on its own will recover. Withdraw \
          them all and each one asks again the next time you use it."],
      form
        (Todo.hidden ({} : Middleware.AntiForgeryOptions).paramName token
          ++ [(button ["Disconnect every assistant"] : Node .flow)])
        { method := "post", action := links.disconnect } ]
    { class_ := "withdraw" }

def connectPage (endpoint : String) (token : Option String) (disconnected : Bool := false) :
    String :=
  let confirmation : List (Node .flow) :=
    if disconnected then
      [p ["Disconnected. Every assistant will ask again the next time you use it."]
        { class_ := "note" }]
    else []
  cardPage "Use your own agent"
    ([ h2 ["Use your own agent"] ] ++ confirmation ++
    [ p ["Your own assistant can work on this list too, the same way the one here does."],
      p ["Assistants differ in where that setting lives, and they move it, so rather than \
          guess at yours: copy this and paste it to your assistant, and let it tell you."],
      Html.label ["Paste this to your assistant"] { for_ := "agent-prompt" },
      textarea (agentPrompt endpoint)
        { id := "agent-prompt", class_ := "prompt", rows := some "14", readonly := true },
      -- The one place on this site a browser needs telling what to do, and `connect.js` is what
      -- tells it. Without the script the button is inert, which is why it names its source in an
      -- attribute rather than being wired up by position: a page that renders it is a page that
      -- has said what it copies.
      p [button ["Copy"] { type := "button", class_ := "copy" } [("data-copy", "agent-prompt")]],
      p ["Nothing in it is secret, so it is safe to paste anywhere you would paste a web \
          address."] { class_ := "note" },
      Html.label ["What it will ask for"],
      ul (Todo.Authorization.scopes.map scopeLine),
      p ["You choose, when it asks. Either one can be refused, and an assistant that is given \
          only the first can read the list and not change it."],
      details
        [ summary ["If your assistant cannot do it"],
          p ["Not every assistant can reach an MCP server, and some can only on a paid plan. \
              An assistant that asks you for the address directly wants this one:"],
          p [code [endpoint]] { class_ := "endpoint" },
          p ["It needs no key beside it. Anything else it asks for, it will find for itself \
              at that address."] ]
        { class_ := "aside" } ]
    ++ [disconnectSection token, p [a { href := links.index } ["Back to your list"]]])
    [connectScript]

end Todo
