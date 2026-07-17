import Std.Http.Server
import SQLite
import Html
import Routing
import Forms
import Todo.Db
import Todo.Links
import Todo.Views

open Std Async
open Std Http Server
open Html
open Routing
open Forms
open Routes

namespace Todo

def render (db : SQLite) (filter : Filter)
    (renderHtml : Array Item → Array Item → Filter → String) :
    ContextAsync (Response Body.Any) := do
  let items ← list db filter
  let allItems ← list db .all
  renderHtml items allItems filter |> Response.ok.html

/-- Renders the fragment for the filter the client's currently viewing (`HX-Current-URL`) --
what every mutating route responds with. -/
def renderMutation (db : SQLite) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  let currentFilter := match req.line.headers.get? (.ofString! "hx-current-url") with
  | some v => filterFromPath v.value
  | none => .all
  render db currentFilter mutationFragment

def pageHandler (filter : Filter) (db : SQLite) (_req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  render db filter pageView

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the DB changes), so unlike
every other route below it targets and returns just that one item, not the whole list section. -/
def editHandler (db : SQLite) (id : Nat) (_req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← list db .all
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

def addHandler (db : SQLite) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let fields ← parseForm req.body
  add db (fields.lookup "title" |>.getD "")
  renderMutation db req

def saveHandler (db : SQLite) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let fields ← parseForm req.body
  setTitle db (Int64.ofNat id) (fields.lookup "title" |>.getD "")
  renderMutation db req

def toggleHandler (db : SQLite) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  toggle db (Int64.ofNat id)
  renderMutation db req

def deleteHandler (db : SQLite) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  delete db (Int64.ofNat id)
  renderMutation db req

def toggleAllHandler (db : SQLite) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  toggleAll db
  renderMutation db req

def clearCompletedHandler (db : SQLite) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  clearCompleted db
  renderMutation db req

def app (db : SQLite) : StatelessHandler :=
  List.map (· db) [
    .get patterns.index ∘ pageHandler .all,
    .get patterns.active ∘ pageHandler .active,
    .get patterns.completed ∘ pageHandler .completed,
    .post patterns.todos ∘ addHandler,
    .get patterns.edit ∘ editHandler,
    .put patterns.todo ∘ saveHandler,
    .post patterns.toggle ∘ toggleHandler,
    .delete patterns.todo ∘ deleteHandler,
    .post patterns.toggleAll ∘ toggleAllHandler,
    .delete patterns.clearCompleted ∘ clearCompletedHandler
  ] |> toHandler

end Todo
