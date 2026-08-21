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
public import Todo.Auth
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

open Auth (Identity)

/-! ## Responses that send the browser somewhere -/

private def headerValue (text : String) : Header.Value :=
  (Header.Value.ofString? text).getD default

private def withHeader (response : Response Body.Any) (name : Header.Name) (value : String) :
    Response Body.Any :=
  { response with
    line := { response.line with
      headers := response.line.headers.insert name (headerValue value) } }

private def signInPath : String :=
  Authentication.BaseUrl.tenantPath Todo.tenant ++ "/signin"

/-- Where a request with no session is sent. A path the tenant does not allow back to becomes its
default, so naming the current one costs nothing and returns whoever was reading a filtered list
to that list.

HTMX follows a redirect itself and swaps whatever it finds into the target element, which would
put the sign-in page inside the todo list. A request it made is told to navigate instead. -/
private def toSignIn (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let target := signInPath ++ "?returnTo=" ++ toString req.line.uri.path
  if (req.line.headers.get? (Header.Name.mk "hx-request")).isSome then
    pure (withHeader (← Response.ok.html "") (Header.Name.mk "hx-redirect") target)
  else
    pure (withHeader (← Response.withStatus .seeOther |>.html "")
      (Header.Name.mk "location") target)

/-! ## Rendering -/

def render (store : Store) (account : Account) (parent : Option SpanContext) (filter : Filter)
    (renderHtml : Array Item → Array Item → Filter → String) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list account filter).run parent
  let allItems ← (store.list account .all).run parent
  renderHtml items allItems filter |> Response.ok.html

/-- Renders the fragment for whichever filter the client is currently viewing, per the
`HX-Current-URL` header HTMX sends with every request. -/
def renderMutation (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  let currentFilter := match req.line.headers.get? (.ofString! "hx-current-url") with
  | some v => filterFromPath v.value
  | none => .all
  render store account (parentSpan req) currentFilter mutationFragment

/-! ## Handlers -/

def pageHandler (filter : Filter) (store : Store) (identity : Identity) (account : Account)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let address ← (identity.address account : IO _)
  render store account (parentSpan req) filter
    (pageView ((req.extensions.get AntiForgeryToken).map (·.value)) address)

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the store changes), so
unlike every other route below it targets and returns just that one item, not the whole list
section. -/
def editHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list account .all).run (parentSpan req)
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

def title? (req : Request Body.Stream) : Option String :=
  (req.extensions.get Params).bind (·.get "title")

def addHandler (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match title? req with
  | some title => (store.add account title).run (parentSpan req); renderMutation store account req
  | none => "Missing title" |> Response.badRequest.text

def saveHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match title? req with
  | some title =>
    (store.setTitle account (Int64.ofNat id) title).run (parentSpan req)
    renderMutation store account req
  | none => "Missing title" |> Response.badRequest.text

def toggleHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.toggle account (Int64.ofNat id)).run (parentSpan req)
  renderMutation store account req

def deleteHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.delete account (Int64.ofNat id)).run (parentSpan req)
  renderMutation store account req

def toggleAllHandler (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.toggleAll account).run (parentSpan req)
  renderMutation store account req

def clearCompletedHandler (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (store.clearCompleted account).run (parentSpan req)
  renderMutation store account req

/-- Ends this browser's session and clears the cookie carrying it. Clearing without revoking
would leave a credential that still works in the hands of whoever recovers the cookie, and
revoking without clearing would send it on every request until it expired. -/
def signOutHandler (identity : Identity) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  (identity.signOut req account : IO Unit)
  let cleared :=
    (SetCookie.serialize
      { name := Auth.sessionCookie
        value := ""
        attrs := { path := some "/", maxAge := some 0, httpOnly := true } }).2
  let response ← Response.ok.html ""
  pure (withHeader { response with
    line := { response.line with
      headers := response.line.headers.insert Header.Name.setCookie cleared } }
    (Header.Name.mk "hx-redirect") signInPath)

/-! ## The router -/

/-- Everything below needs to know who is asking, so establishing it is the router's job rather
than each handler's. A request with no live session never reaches one. -/
private def guarded (identity : Identity)
    (handler : Account → Request Body.Stream → ContextAsync (Response Body.Any)) :
    Request Body.Stream → ContextAsync (Response Body.Any) := fun req => do
  match ← (identity.of req : IO _) with
  | some account => handler account req
  | none => toSignIn req

def app (identity : Identity) (store : Store) : StatelessHandler :=
  let byId (handler : Store → Account → Nat → Request Body.Stream →
      ContextAsync (Response Body.Any)) := fun id =>
    guarded identity (handler store · id ·)
  toHandler [
    .get patterns.index (guarded identity (pageHandler .all store identity)),
    .get patterns.active (guarded identity (pageHandler .active store identity)),
    .get patterns.completed (guarded identity (pageHandler .completed store identity)),
    .post patterns.todos (guarded identity (addHandler store)),
    .get patterns.edit (byId editHandler),
    .put patterns.todo (byId saveHandler),
    .post patterns.toggle (byId toggleHandler),
    .delete patterns.todo (byId deleteHandler),
    .post patterns.toggleAll (guarded identity (toggleAllHandler store)),
    .delete patterns.clearCompleted (guarded identity (clearCompletedHandler store)),
    .post patterns.signOut (guarded identity (signOutHandler identity))
  ]

/-- The sign-in routes carry an anti-forgery token of their own, derived from the attempt cookie
under the server's pepper, and the browser reaching them has no session for `antiForgery` to have
put one in. So they are served beside the application rather than inside it, and everything the
two do share is applied to both.

The tenant's own prefix decides which is which, because that is where the library answers and
where the mail it sends points. -/
private def underAuth (req : Request Body.Stream) : Bool :=
  match req.line.uri.path.toDecodedSegments.toList with
  | "t" :: name :: _ => name == Todo.tenant.value
  | _ => false

private def split (auth application : StatelessHandler) : StatelessHandler :=
  { onRequest := fun req =>
      if underAuth req then auth.onRequest req else application.onRequest req }

/-- The routes wrapped in the middleware stack recommended for a browser-facing site, in
`Middleware.apply`'s documented order.

`https` states whether something in front of this server terminates TLS, which is the only thing
that can establish it: `Std.Http.Server` serves plain http either way. Setting it marks the
session cookie `secure` and sends `hsts`. Claiming it falsely is the damaging direction, since a
`secure` cookie would never come back and `antiForgery` would then reject every mutation.

`sslRedirect` is absent whichever way `https` goes, because neither deployment has a plaintext
listener to redirect a caller away from. -/
def server [SessionStore σ] (identity : Identity) (auth : StatelessHandler) (store : Store)
    (sessions : σ) (https : Bool := false) : StatelessHandler :=
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
          contentType,
          defaultCharset,
          notModified,
          file "public"])
    (split auth (Middleware.apply [antiForgery] (app identity store)))

end Todo
