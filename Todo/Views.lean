import Html
import Htmx
import Todo.Db
import Todo.Links

namespace Todo

open Html
open Routes

def htmxScript : ScriptAttrs :=
  { src := "https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js"
    integrity := "sha384-H5SrcfygHmAuTDZphMHqBJLc3FhssKjG7w/CeCpFReSfwBWDTKpkzPP8c+cLsK+V"
    crossorigin := "anonymous" }

def todomvcCss : LinkAttrs :=
  { rel := "stylesheet", href := "https://unpkg.com/todomvc-app-css@2.4.3/index.css" }

def Filter.path : Filter → String
  | .all => links.index
  | .active => links.active
  | .completed => links.completed

def filterFromPath (path : String) : Filter :=
  if path.endsWith "/active" then .active
  else if path.endsWith "/completed" then .completed
  else .all

def itemView (item : Item) : Node .flow :=
  let itemId := s!"todo-{item.id}"
  let id := item.id.toInt.toNat
  li
    [ div
        [ Htmx.input
            { type := "checkbox", checked := item.completed }
            (hx := { hxPost := links.toggle id, hxTarget := "#todo-list-section",
                     hxSwap := some .outerHTML })
            (attrs := { class_ := "toggle" }),
          Htmx.label [item.title]
            (hx := { hxGet := links.edit id, hxTrigger := "dblclick",
                     hxTarget := s!"#{itemId}", hxSwap := some .outerHTML }),
          Htmx.button [] (hx := { hxDelete := links.todo id, hxTarget := "#todo-list-section",
                                   hxSwap := some .outerHTML })
            (attrs := { class_ := "destroy" }) ]
        (attrs := { class_ := "view" }) ]
    (attrs := { id := itemId, class_ := if item.completed then "completed" else none })

def itemEditView (item : Item) : Node .flow :=
  let itemId := s!"todo-{item.id}"
  li
    [ Htmx.input
        { type := "text", name := "title", value := item.title }
        (hx := { hxPut := links.todo item.id.toInt.toNat, hxTrigger := "blur, keyup[key=='Enter']",
                 hxTarget := "#todo-list-section", hxSwap := some .outerHTML })
        (attrs := { class_ := "edit" })
        (rawAttrs := [("autofocus", "autofocus")]) ]
    (attrs := { id := itemId, class_ := "editing" })

def listSection (items : Array Item) : Node .flow :=
  let allCompleted := items.size > 0 && items.all (·.completed)
  section_
    [ Htmx.input
        { type := "checkbox", checked := allCompleted }
        (hx := { hxPost := links.toggleAll, hxTarget := "#todo-list-section",
                 hxSwap := some .outerHTML })
        (attrs := { id := "toggle-all", class_ := "toggle-all" }),
      label [] (attrs := {}) (rawAttrs := [("for", "toggle-all")]),
      ul (items.toList.map itemView) (attrs := { class_ := "todo-list" }) ]
    (attrs := { id := "todo-list-section", class_ := "main" })

def filterLink (current target : Filter) (label : String) : Node .flow :=
  li [ a { href := target.path } [label]
         (attrs := { class_ := if current == target then "selected" else none }) ]

def countLabel(activeCount : Nat) : String :=
  if activeCount == 1 then "1 item left" else s!"{activeCount} items left"

def footerFragment (allItems : Array Item) (filter : Filter) : Node .flow :=
  let activeCount := (allItems.filter (!·.completed)).size
  let completedCount := allItems.size - activeCount
  Htmx.footer
    ([ (span [countLabel activeCount] (attrs := { class_ := "todo-count" }) : Node .flow),
       ul [ filterLink filter .all "All", filterLink filter .active "Active",
            filterLink filter .completed "Completed" ]
         (attrs := { class_ := "filters" }) ]
      ++ if completedCount > 0 then
           [ (Htmx.button ["Clear completed"]
               (hx := { hxDelete := links.clearCompleted, hxTarget := "#todo-list-section",
                        hxSwap := some .outerHTML })
               (attrs := { class_ := "clear-completed" }) : Node .flow) ]
         else [])
    (hx := { hxSwapOob := "true" }) (attrs := { id := "todo-footer", class_ := "footer" })

def mutationFragment (items allItems : Array Item) (filter : Filter) : String :=
  Node.render (listSection items) ++ Node.render (footerFragment allItems filter)

def page (items allItems : Array Item) (filter : Filter) : String :=
  document (pretty := true) (lang := "en")
    [ head
        [ meta_ [("charset", "utf-8")], title "todos", script htmxScript, link todomvcCss ],
      body
        [ section_
            [ header
                [ h1 ["todos"],
                  Htmx.form
                    [ input
                        { name := "title", placeholder := "What needs to be done?" }
                        (attrs := { class_ := "new-todo" })
                        (rawAttrs := [("autofocus", "autofocus")]) ]
                    (hx := { hxPost := links.todos, hxTarget := "#todo-list-section",
                             hxSwap := some .outerHTML })
                    (rawAttrs := [("hx-on::after-request", "this.reset()")]) ]
                (attrs := { class_ := "header" }),
              listSection items,
              footerFragment allItems filter ]
            (attrs := { class_ := "todoapp" }),
          footer [p ["Double-click a todo to edit it."]] (attrs := { class_ := "info" }) ] ]

end Todo
