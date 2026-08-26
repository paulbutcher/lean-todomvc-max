/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Htmx
public import Crypto.Sha256
public import Codec.Hex
public import Todo.Store
public import Todo.Links
public import Todo.ChatViews

@[expose] public section

namespace Todo

open Html
open Routes

def htmxScript : ScriptAttrs :=
  { src := "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
    integrity := "sha384-H5SrcfygHmAuTDZphMHqBJLc3FhssKjG7w/CeCpFReSfwBWDTKpkzPP8c+cLsK+V"
    crossorigin := "anonymous" }

def todomvcCss : LinkAttrs :=
  { rel := "stylesheet", href := "https://unpkg.com/todomvc-app-css@2.4.3/index.css" }

def favicon : LinkAttrs :=
  { rel := "icon", href := "/favicon.svg" }

/-- The panel and the split it sits in. Separate from `todomvcCss`, which is the unmodified
TodoMVC stylesheet and is left that way: the list still has to look like the one the spec
describes, and everything here is around it rather than in it. -/
def chatCss : LinkAttrs :=
  { rel := "stylesheet", href := "/chat.css" }

def chatScript : ScriptAttrs :=
  { src := "/chat.js" }

/-- What the sign-in pages and the connect page need beyond todomvc-app-css, which styles a list
and not prose. -/
def authCss : LinkAttrs :=
  { rel := "stylesheet", href := "/auth.css" }

/-- A page that is read rather than worked in, in the shell the todo list uses so that leaving
the list does not look like leaving the site. The heading floats above the card on
`todomvc-app-css`'s own positioning; it is here for that rather than to say anything. -/
def cardPage (heading : String) (children : List (Node .flow)) : String :=
  document
    [ head
        [ meta_ [("charset", "utf-8")],
          meta_ [("name", "viewport"), ("content", "width=device-width, initial-scale=1")],
          title heading, link todomvcCss, link authCss, link favicon ],
      body
        [ section_
            [ header [h1 ["todos"]] { class_ := "header" },
              div children { class_ := "auth" } ]
            { class_ := "todoapp" } ] ]
    (lang := "en")

/-- Puts the anti-forgery token on `<body>` as an `hx-headers` attribute, which HTMX inherits
down the whole tree, so every mutating request below carries it. `none` when no `antiForgery`
middleware established a token, in which case there's nothing to send. -/
def csrfAttrs : Option String → List (String × String)
  | none => []
  | some token => [("hx-headers", "{\"X-CSRF-Token\": \"" ++ token ++ "\"}")]

def Filter.path : Filter → String
  | .all => links.index
  | .active => links.active
  | .completed => links.completed

def filterFromPath (path : String) : Filter :=
  if path.endsWith "/active" then .active
  else if path.endsWith "/completed" then .completed
  else .all

def itemView (item : Item) : Node .listItem :=
  let itemId := s!"todo-{item.id}"
  let id := item.id.toInt.toNat
  li
    [ div
        [ Htmx.input
            { type := "checkbox", checked := item.completed, class_ := "toggle",
              hxPost := links.toggle id, hxTarget := "#todo-list-section",
              hxSwap := some .outerHTML },
          Htmx.label [item.title]
            { hxGet := links.edit id, hxTrigger := "dblclick",
              hxTarget := s!"#{itemId}", hxSwap := some .outerHTML },
          Htmx.button []
            { class_ := "destroy", hxDelete := links.todo id,
              hxTarget := "#todo-list-section", hxSwap := some .outerHTML } ]
        { class_ := "view" } ]
    { id := itemId, class_ := if item.completed then "completed" else none }

def itemEditView (item : Item) : Node .listItem :=
  let itemId := s!"todo-{item.id}"
  li
    [ Htmx.input
        { type := "text", name := "title", value := item.title, class_ := "edit",
          hxPut := links.todo item.id.toInt.toNat, hxTrigger := "blur, keyup[key=='Enter']",
          hxTarget := "#todo-list-section", hxSwap := some .outerHTML }
        [("autofocus", "autofocus")] ]
    { id := itemId, class_ := "editing" }

/-! ## Noticing that the list has changed underneath the page -/

/-- Everything the list and its footer are drawn from, so that two lists differing anywhere the
person can see differ here. Both are functions of the account's whole list; which of them the
filter admits is settled from the same data.

A digest rather than a revision column because it needs no schema and no shared state: the
deployed function freezes between invocations and runs as several instances, so a counter held
anywhere but the rows themselves would be wrong on at least one of them. -/
def listDigest (allItems : Array Item) : String :=
  let canonical := allItems.foldl (init := "") fun acc item =>
    acc ++ s!"{item.id}\x1f{item.completed}\x1f{item.title}\x1e"
  Codec.Hex.encodeString (Crypto.Sha256.hashUtf8 canonical)

/-- How often the page asks whether the list still matches what it is showing.

Short polls rather than one held open: a held request keeps an invocation of the deployed function
alive for its whole duration, and unlike the assistant's poll there is no work going on underneath
that the invocation is needed for. -/
def watchInterval : String := "5s"

/-- What asks. It carries the digest of the list it was drawn beside, so the answer is a swap
only when the two have parted company.

It sits inside the section rather than beside it so that every path that redraws the list redraws
this too: a watcher left holding a stale digest would swap the list on its next poll for no
reason, and an unprompted swap discards a todo somebody is part-way through editing. -/
def listWatcher (digest : String) : Node .flow :=
  Htmx.div []
    { id := "todo-watch",
      hxGet := s!"{links.todosStatus}?seen={digest}",
      hxTrigger := s!"every {watchInterval}",
      -- The answer is either nothing at all or an out-of-band swap, neither of which belongs
      -- anywhere this element is.
      hxSwap := some .none }

/-- `oob` marks this as an out-of-band swap, for a response the browser is not aiming at the list:
the assistant's poll answers into the chat panel, and grafts the list on beside it. Every other
caller is answering a request that targeted the list, where saying so again would be redundant. -/
def listSection (items : Array Item) (digest : String) (oob : Bool := false) : Node .flow :=
  let allCompleted := items.size > 0 && items.all (·.completed)
  Htmx.section_
    [ Htmx.input
        { type := "checkbox", checked := allCompleted, id := "toggle-all",
          class_ := "toggle-all", hxPost := links.toggleAll,
          hxTarget := "#todo-list-section", hxSwap := some .outerHTML },
      label [] { for_ := "toggle-all" },
      ul (items.toList.map itemView) { class_ := "todo-list" },
      listWatcher digest ]
    { id := "todo-list-section", class_ := "main",
      hxSwapOob := if oob then some "true" else none }

def filterLink (current target : Filter) (label : String) : Node .listItem :=
  li [ a { href := target.path,
           class_ := if current == target then "selected" else none } [label] ]

def countLabel(activeCount : Nat) : String :=
  if activeCount == 1 then "1 item left" else s!"{activeCount} items left"

def footerFragment (allItems : Array Item) (filter : Filter) : Node .flow :=
  let activeCount := (allItems.filter (!·.completed)).size
  let completedCount := allItems.size - activeCount
  Htmx.footer
    ([ (span [countLabel activeCount] { class_ := "todo-count" } : Node .flow),
       ul [ filterLink filter .all "All", filterLink filter .active "Active",
            filterLink filter .completed "Completed" ]
         { class_ := "filters" } ]
      ++ if completedCount > 0 then
           [ (Htmx.button ["Clear completed"]
               { class_ := "clear-completed", hxDelete := links.clearCompleted,
                 hxTarget := "#todo-list-section", hxSwap := some .outerHTML } : Node .flow) ]
         else [])
    { id := "todo-footer", class_ := "footer", hxSwapOob := "true" }

def mutationFragment (items allItems : Array Item) (filter : Filter) : String :=
  Node.render (listSection items (listDigest allItems))
    ++ Node.render (footerFragment allItems filter)

/-- The same two fragments, for a response aimed somewhere else entirely. The footer already
swaps out of band wherever it appears, since it is never what a request targets. -/
def listRefreshFragment (items allItems : Array Item) (filter : Filter) : String :=
  Node.render (listSection items (listDigest allItems) (oob := true))
    ++ Node.render (footerFragment allItems filter)

/-- The address is what makes the session visible; the account id it hangs off says nothing to
the person holding it. `none` only where the account has gone between being identified and being
read, which the sign-out below is the remedy for either way. -/
def accountFooter (address : Option String) : Node .flow :=
  footer
    ([ (p ["Double-click a todo to edit it."] : Node .flow) ]
      ++ (match address with
          | none => []
          | some address => [(p [s!"Signed in as {address}"] : Node .flow)])
      ++ [ (Htmx.button ["Sign out"]
              { class_ := "sign-out", hxPost := links.signOut } : Node .flow) ])
    { class_ := "info" }

/-- The list and the panel side by side, with a divider between them that `chat.js` makes
draggable. The width the drag settles on is the browser's to remember, not the server's: it is a
property of the window being read in, not of the account, and an account read on two screens
wants two different answers. -/
def appShell (address : Option String) (messages : Array LLMClient.Msg) (turn : Option TurnState)
    (main : List (Node .flow)) : Node .flow :=
  div
    [ div (main ++ [accountFooter address]) { class_ := "app-pane", id := "app-pane" },
      div [] { class_ := "app-divider", id := "app-divider" },
      chatPanel messages turn ]
    { class_ := "app-shell" }

def pageView (csrfToken : Option String) (address : Option String)
    (messages : Array LLMClient.Msg) (turn : Option TurnState) (items allItems : Array Item)
    (filter : Filter) : String :=
  document
    [ head
        [ meta_ [("charset", "utf-8")], title "todos", script htmxScript, script chatScript,
          link todomvcCss, link chatCss, link favicon ],
      body
        [ appShell address messages turn
            [ section_
                [ header
                    [ h1 ["todos"],
                      Htmx.form
                        [ input
                            { name := "title", placeholder := "What needs to be done?",
                              class_ := "new-todo" }
                            [("autofocus", "autofocus")] ]
                        { hxPost := links.todos, hxTarget := "#todo-list-section",
                          hxSwap := some .outerHTML,
                          hxOnHtmx := [("after-request", "this.reset()")] } ]
                    { class_ := "header" },
                  listSection items (listDigest allItems),
                  footerFragment allItems filter ]
                { class_ := "todoapp" } ] ]
        (rawAttrs := csrfAttrs csrfToken) ]
    (lang := "en")

end Todo
