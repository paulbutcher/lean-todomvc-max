/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server
import SQLite
import Html
import Routing
import Middleware
import Todo.Db
import Todo.Links
import Todo.Views

open Std Async
open Std Http Server
open Html
open Routing
open Middleware
open Routes

namespace Todo

def render (db : SQLite) (filter : Filter)
    (renderHtml : Array Item → Array Item → Filter → String) :
    ContextAsync (Response Body.Any) := do
  let items ← list db filter
  let allItems ← list db .all
  renderHtml items allItems filter |> Response.ok.html

/-- Renders the fragment for whichever filter the client is currently viewing, per the
`HX-Current-URL` header HTMX sends with every request. -/
def renderMutation (db : SQLite) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  let currentFilter := match req.line.headers.get? (.ofString! "hx-current-url") with
  | some v => filterFromPath v.value
  | none => .all
  render db currentFilter mutationFragment

def pageHandler (filter : Filter) (db : SQLite) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  render db filter (pageView ((req.extensions.get AntiForgeryToken).map (·.value)))

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the DB changes), so unlike
every other route below it targets and returns just that one item, not the whole list section. -/
def editHandler (db : SQLite) (id : Nat) (_req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← list db .all
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

def title? (req : Request Body.Stream) : Option String :=
  (req.extensions.get Params).bind (·.get "title")

def addHandler (db : SQLite) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  match title? req with
  | some title => add db title; renderMutation db req
  | none => "Missing title" |> Response.badRequest.text

def saveHandler (db : SQLite) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match title? req with
  | some title => setTitle db (Int64.ofNat id) title; renderMutation db req
  | none => "Missing title" |> Response.badRequest.text

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

/-- The routes wrapped in the middleware stack recommended for a browser-facing site, in
`Middleware.apply`'s documented order. `hsts` and `sslRedirect` are left out because this server
is run directly over plain http rather than behind a TLS-terminating reverse proxy; that's also
why the session cookie can't be marked `secure`, since a `secure` cookie would never come back
and `antiForgery` would then reject every mutation. -/
def server [SessionStore σ] (db : SQLite) (sessions : σ) : StatelessHandler :=
  Middleware.apply
    [forwardedScheme, forwardedRemoteAddr,
     xFrameOptions .sameOrigin, xContentTypeOptions,
     catchAll,
     cookies,
     session sessions
       { cookieName := "todomvc-session",
         cookieAttrs := { path := some "/", httpOnly := true, sameSite := some .lax } },
     params,
     antiForgery,
     contentType,
     defaultCharset,
     notModified,
     file "public"]
    (app db)

end Todo
