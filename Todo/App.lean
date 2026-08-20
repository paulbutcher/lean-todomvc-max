/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Server
public import Html
public import Routing
public import Middleware
public import MiddlewareTracing
public import Todo.Store
public import Todo.Links
public import Todo.Views

public section

open Std Async
open Std Http Server
open Html
open Routing
open Middleware
open Routes
open Telemetry (SpanContext)

namespace Todo

def render (store : Store) (parent : Option SpanContext) (filter : Filter)
    (renderHtml : Array Item → Array Item → Filter → String) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list filter).run parent
  let allItems ← (store.list .all).run parent
  renderHtml items allItems filter |> Response.ok.html

/-- Renders the fragment for whichever filter the client is currently viewing, per the
`HX-Current-URL` header HTMX sends with every request. -/
def renderMutation (store : Store) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  let currentFilter := match req.line.headers.get? (.ofString! "hx-current-url") with
  | some v => filterFromPath v.value
  | none => .all
  render store (parentSpan req) currentFilter mutationFragment

def pageHandler (filter : Filter) (store : Store) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  render store (parentSpan req) filter
    (pageView ((req.extensions.get AntiForgeryToken).map (·.value)))

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the store changes), so
unlike every other route below it targets and returns just that one item, not the whole list
section. -/
def editHandler (store : Store) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list .all).run (parentSpan req)
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

def title? (req : Request Body.Stream) : Option String :=
  (req.extensions.get Params).bind (·.get "title")

def addHandler (store : Store) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match title? req with
  | some title => (store.add title).run (parentSpan req); renderMutation store req
  | none => "Missing title" |> Response.badRequest.text

def saveHandler (store : Store) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match title? req with
  | some title =>
    (store.setTitle (Int64.ofNat id) title).run (parentSpan req); renderMutation store req
  | none => "Missing title" |> Response.badRequest.text

def toggleHandler (store : Store) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.toggle (Int64.ofNat id)).run (parentSpan req)
  renderMutation store req

def deleteHandler (store : Store) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.delete (Int64.ofNat id)).run (parentSpan req)
  renderMutation store req

def toggleAllHandler (store : Store) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  store.toggleAll.run (parentSpan req)
  renderMutation store req

def clearCompletedHandler (store : Store) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  store.clearCompleted.run (parentSpan req)
  renderMutation store req

def app (store : Store) : StatelessHandler :=
  List.map (· store) [
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
`Middleware.apply`'s documented order.

`https` states whether something in front of this server terminates TLS, which is the only thing
that can establish it: `Std.Http.Server` serves plain http either way. Setting it marks the
session cookie `secure` and sends `hsts`. Claiming it falsely is the damaging direction, since a
`secure` cookie would never come back and `antiForgery` would then reject every mutation.

`sslRedirect` is absent whichever way `https` goes, because neither deployment has a plaintext
listener to redirect a caller away from. -/
def server [SessionStore σ] (store : Store) (sessions : σ) (https : Bool := false) :
    StatelessHandler :=
  Middleware.apply
    ([forwardedScheme, forwardedRemoteAddr]
      ++ (if https then [hsts] else [])
      ++ [xFrameOptions .sameOrigin, xContentTypeOptions,
          catchAll,
          serverSpan matchedPattern?,
          cookies,
          session sessions
            { cookieName := "todomvc-session",
              cookieAttrs := { path := some "/", httpOnly := true, sameSite := some .lax,
                               secure := https } },
          params,
          antiForgery,
          contentType,
          defaultCharset,
          notModified,
          file "public"])
    (app store)

end Todo
