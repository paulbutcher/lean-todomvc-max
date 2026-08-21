/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Htmx
public import Todo.Store
public import Todo.Links

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

def listSection (items : Array Item) : Node .flow :=
  let allCompleted := items.size > 0 && items.all (·.completed)
  section_
    [ Htmx.input
        { type := "checkbox", checked := allCompleted, id := "toggle-all",
          class_ := "toggle-all", hxPost := links.toggleAll,
          hxTarget := "#todo-list-section", hxSwap := some .outerHTML },
      label [] { for_ := "toggle-all" },
      ul (items.toList.map itemView) { class_ := "todo-list" } ]
    { id := "todo-list-section", class_ := "main" }

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
  Node.render (listSection items) ++ Node.render (footerFragment allItems filter)

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

def pageView (csrfToken : Option String) (address : Option String) (items allItems : Array Item)
    (filter : Filter) : String :=
  document
    [ head
        [ meta_ [("charset", "utf-8")], title "todos", script htmxScript, link todomvcCss,
          link favicon ],
      body
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
              listSection items,
              footerFragment allItems filter ]
            { class_ := "todoapp" },
          accountFooter address ]
        (rawAttrs := csrfAttrs csrfToken) ]
    (lang := "en")

end Todo
