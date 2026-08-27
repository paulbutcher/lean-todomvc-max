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
public import Todo.ConnectViews
public import Todo.ChatTurn
public import Todo.Mcp

public section

open Std Async
open Std Http Server
open Html
open Routing
open Middleware
open Routes
open Telemetry (SpanContext TelemetryT)

namespace Todo

open Auth (Identity)

/-! ## Responses that send the browser somewhere -/

private def withHeader (response : Response Body.Any) (name : Header.Name) (value : String) :
    Response Body.Any :=
  { response with
    line := { response.line with
      headers := response.line.headers.insert name (Header.Value.ofStringSanitized value) } }

/-- The request as it was addressed, parameters included. Whether the parameters matter depends
on what they are for: a page keeps none, and an authorization request is nothing without them, so
carrying them is what lets one survive a detour through signing in. The allowlist is matched
against the path alone, so nothing here can widen what a `returnTo` may name.

The one reader left that takes its parameters from the extension rather than from `withParams`,
because this runs for a request with no session on any route, which is outside it. Losing the
query here costs a redirect back to a less specific page; refusing to redirect at all would cost
the sign-in. -/
def target (req : Request Body.Stream) : String :=
  let path := toString req.line.uri.path
  match (req.extensions.get Params).map (·.query) with
  | some query => if query.isEmpty then path else path ++ "?" ++ query.toRawString
  | none => path

/-- Where a request with no session is sent. A path the tenant does not allow back to becomes its
default, so naming the current one costs nothing and returns whoever was reading a filtered list
to that list.

HTMX follows a redirect itself and swaps whatever it finds into the target element, which would
put the sign-in page inside the todo list. A request it made is told to navigate instead. -/
private def toSignIn (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  -- Encoded rather than concatenated: an authorization request has parameters of its own, and
  -- pasted in raw the first `&` of them would end the `returnTo` and start a parameter of the
  -- sign-in route's.
  let target := signInPath ++ "?" ++ (URI.Query.empty.insert "returnTo" (target req)).toRawString
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

/-- Which filter the client is currently viewing, per the `HX-Current-URL` header HTMX sends with
every request. A fragment has to be rendered for the list the person is actually looking at, not
for the one the route it came from would imply. -/
def currentFilter (req : Request Body.Stream) : Filter :=
  match req.line.headers.get? (Header.Name.mk "hx-current-url") with
  | some v => filterFromPath v.value
  | none => .all

def renderMutation (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  render store account (parentSpan req) (currentFilter req) mutationFragment

/-- The list as it now stands, for grafting onto a response aimed somewhere else. Returned as a
string rather than a response because the caller has its own body to put this after. -/
def listRefresh (store : Store) (account : Account) (req : Request Body.Stream) :
    ContextAsync String := do
  let parent := parentSpan req
  let filter := currentFilter req
  let items ← (store.list account filter).run parent
  let allItems ← (store.list account .all).run parent
  pure (listRefreshFragment items allItems filter)

/-! ## Handlers -/

def pageHandler (filter : Filter) (store : Store) (assistant : Assistant) (identity : Identity)
    (account : Account) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let address ← (identity.address account : IO _)
  let parent := parentSpan req
  let messages ← (assistant.chat.history account).run parent
  -- A reload during a turn rejoins it rather than showing a conversation that stops mid-question:
  -- the panel comes back polling, exactly as the request that started the turn left it.
  let turn ← (assistant.turns.get account : IO _)
  render store account parent filter
    (pageView ((req.extensions.get AntiForgeryToken).map (·.value)) address messages turn)

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the store changes), so
unlike every other route below it targets and returns just that one item, not the whole list
section. -/
def editHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list account .all).run (parentSpan req)
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

def title? (params : Params) : Option String := params.get "title"

/-- How many of the turn's mutations the fragment that sent this poll was drawn against. Missing
or unreadable reads as none, which costs a redundant refresh rather than a missed one. -/
def seen? (params : Params) : Nat := ((params.get "seen").bind (·.toNat?)).getD 0

def addHandler (store : Store) (account : Account) (params : Params)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  match title? params with
  | some title => (store.add account title).run (parentSpan req); renderMutation store account req
  | none => "Missing title" |> Response.badRequest.text

def saveHandler (store : Store) (account : Account) (id : Nat) (params : Params)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  match title? params with
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

/-- The digest the fragment that sent this poll was drawn against. Missing or unreadable matches
no list, which costs a redundant refresh rather than a missed one. -/
def seenDigest (params : Params) : String := (params.get "seen").getD ""

/-- Answers the page's standing question of whether the list it is showing is still the list the
store holds, and says nothing at all when it is.

This is what makes a change the browser did not make visible: an agent reaching the tools over
MCP, the assistant panel in another tab, or the same account on a phone. Nothing else asks, since
the assistant's own poll runs only while a turn is in flight.

Answering with the list only when the digest has moved is not an optimisation. An unprompted swap
discards a todo somebody is part-way through editing inline, so a poll that refreshed on every
tick would make inline editing impossible to finish. -/
def listStatusHandler (store : Store) (account : Account) (params : Params)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let parent := parentSpan req
  let allItems ← (store.list account .all).run parent
  if listDigest allItems == seenDigest params then
    "" |> Response.ok.html
  else
    let filter := currentFilter req
    let items ← (store.list account filter).run parent
    listRefreshFragment items allItems filter |> Response.ok.html

/-- The address of the MCP endpoint, and what to hand an assistant of your own so that it can
set itself up against it. Behind the session like the rest of the application, though nothing on
it is private: what it describes is this account's list, and somebody reading it has one. -/
def connectHandler (authorization : Authorization.Site) (_account : Account)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  connectPage authorization.endpoint ((req.extensions.get AntiForgeryToken).map (·.value))
    |> Response.ok.html

/-- Withdraws every approval this account has given, and says so on the page it was asked from.

The page rather than a redirect because there is nothing to carry a message through one, and
answering the `POST` costs only a resubmission on refresh, which withdraws what is already
withdrawn. -/
def disconnectHandler (authorization : Authorization.Site) (account : Account)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let revoked ← (authorization.disconnect account : IO Nat)
  (Telemetry.info "every agent disconnected" [("oauth.connections_revoked", .int revoked)]
    : TelemetryT Async Unit).run (parentSpan req)
  connectPage authorization.endpoint ((req.extensions.get AntiForgeryToken).map (·.value))
    (disconnected := true) |> Response.ok.html

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

/-! ## The assistant panel -/

def prompt? (params : Params) : Option String :=
  (params.get "prompt").map (·.trimAscii.toString) |>.filter (!·.isEmpty)

/-- The panel's transcript, which is what every route below answers with: each of them changes
what the conversation is and then shows what it has become, so none of them needs a reply shape
of its own. -/
def conversation (assistant : Assistant) (account : Account) (parent : Option SpanContext) :
    ContextAsync (Response Body.Any) := do
  let messages ← (assistant.chat.history account).run parent
  let turn ← (assistant.turns.get account : IO _)
  Node.render (conversationView messages turn) |> Response.ok.html

/-- Takes a prompt, starts a turn for it, and answers with the transcript the prompt is now in,
without waiting for a word of the reply. That is what puts the prompt on the page as soon as it
is sent; the reply arrives through `chatStatusHandler` as the panel polls for it.

Claiming the turn before storing the prompt is what keeps a second prompt sent during a turn from
being stored with nothing to answer it: it is dropped instead, and the panel it returns to is
already showing the turn that is running.

A blank prompt is not a turn. It re-renders, which is what an empty send should look like. -/
def chatHandler (store : Store) (assistant : Assistant) (account : Account)
    (params : Params) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let parent := parentSpan req
  if let some prompt := prompt? params then
    if ← (assistant.turns.claim account : IO _) then
      (assistant.chat.append account #[.user prompt]).run parent
      (startTurn assistant store account parent : IO Unit)
  conversation assistant account parent

/-- How long a poll waits for the turn to move before answering with where it had got to, and how
often it looks while it waits.

Waiting rather than answering at once is what makes this work on a deployment that freezes the
execution environment between invocations: the turn runs on a thread of its own, and that thread
is only scheduled while an invocation is in flight. A poll that returned immediately would leave
it frozen for all but a sliver of each interval, and a turn would take minutes of wall clock to
do seconds of work.

Well inside the deployed function's own timeout, so a turn that runs long is a series of polls
that each return something rather than one that is cut off. -/
private def pollWait : Nat := 25
private def pollInterval : Std.Time.Millisecond.Offset := 200

/-- One poll, held open until the turn moves or `pollWait` intervals go by.

Reading a failed turn is what clears it, so the message is shown once and the panel showing it
has already stopped asking; leaving it would report the same failure against every turn after it.

`Async.sleep` rather than blocking: this is a fiber sharing its thread with every other request in
flight, and holding the thread for the wait would stall all of them. -/
def chatStatusHandler (store : Store) (assistant : Assistant) (account : Account)
    (params : Params) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let mut turn ← (assistant.turns.get account : IO _)
  for _ in [0:pollWait] do
    if !turn.any (·.phase.isRunning) then break
    liftM (Async.sleep pollInterval)
    turn ← (assistant.turns.get account : IO _)
  let messages ← (assistant.chat.history account).run (parentSpan req)
  -- The list is grafted on when a tool has changed it since the fragment that asked was drawn,
  -- and again when the turn ends. The second is what covers a change made between the last poll
  -- and the reply, and the turn's own entry is gone by then to have been compared against.
  -- Refreshing once more than strictly needed costs a swap; refreshing once too few leaves the
  -- person looking at a list that disagrees with what the assistant says it did.
  let ended := !turn.any (·.phase.isRunning)
  let moved := turn.any (·.mutations > seen? params)
  if turn.any (!·.phase.isRunning) then (assistant.turns.finish account : IO Unit)
  let conversation := Node.render (conversationView messages turn)
  let refresh ← if ended || moved then listRefresh store account req else pure ""
  conversation ++ refresh |> Response.ok.html

/-- Forgets the conversation, so that the next prompt is answered without what came before it
being replayed to the model.

A turn in flight is left alone, and so is the transcript under it: the reply is already being
written and would land in the emptied conversation looking like an answer to whatever was asked
next. Whoever asked can clear it once it has arrived. -/
def chatResetHandler (assistant : Assistant) (account : Account) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let parent := parentSpan req
  let turn ← (assistant.turns.get account : IO _)
  unless turn.any (·.phase.isRunning) do
    (assistant.chat.clear account).run parent
    (assistant.turns.finish account : IO Unit)
  conversation assistant account parent

/-! ## The authorization server

Everything below answers a client rather than a person, except the authorization endpoint, which
is where the two meet. -/

/-- `Status` from the code the library names, which is the whole of what it says about how a
failure is reported. -/
private def statusOf (code : Nat) : Status :=
  (Status.ofCode none code.toUInt16).getD .badRequest

private def jsonResponse (code : Nat) (body : Json) : ContextAsync (Response Body.Any) := do
  let response ← Response.withStatus (statusOf code) |>.json (Json.compress body)
  -- OAuth 2.1 §3.2.3: nothing an endpoint here answers with may be held by a cache, and the
  -- tokens are the reason.
  pure (withHeader response (Header.Name.mk "cache-control") "no-store")

private def refused (refusal : Authorization.Refusal) : ContextAsync (Response Body.Any) :=
  jsonResponse refusal.status refusal.toJson

/-- The parameters as the request sent them, from wherever that request carries them: the
authorization request in the query string, the token and registration requests in the body. They
are read apart rather than merged, because a token request that took a parameter from the query
would read one the client did not sign up to send there. -/
private def queryParams (params : Params) : Authorization.Params :=
  Authorization.params params.query

private def formParams (params : Params) : Authorization.Params :=
  Authorization.params params.form

def metadataHandler (site : Authorization.Site) (_req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  jsonResponse 200 site.metadata

/-- What a client that was refused at the MCP endpoint follows to find out where to ask for a
token. -/
def resourceMetadataHandler (site : Authorization.Site) (_req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  jsonResponse 200 site.resourceMetadata

private def seeOther (location : String) : ContextAsync (Response Body.Any) := do
  let response ← Response.withStatus .seeOther |>.html ""
  pure (withHeader response (Header.Name.mk "location") location)

/-- The three outcomes that need nothing further asked. `consent` is the fourth and is the
caller's, because what it does with one depends on whether the person has answered yet. -/
private def settle (req : Request Body.Stream)
    (asked : Authorization.Prompt → ContextAsync (Response Body.Any)) :
    Authorization.Outcome → ContextAsync (Response Body.Any)
  | .respond redirect => seeOther redirect.location
  | .refuse error => refusedClientPage error.description |> Response.badRequest.html
  | .authenticate => toSignIn req
  | .consent prompt => asked prompt

/-- Which scopes the person left ticked, narrowed by `conclude` to what was asked for either way.

Anything but `allow` is a refusal, which is what makes the deny button ordinary rather than
special: a submission that reaches here without saying `allow` has not granted anything. So is
allowing with every box unticked, which `conclude` settles: an approval narrowing to nothing is
the same answer as denying. -/
private def decisionFor (params : Params) (prompt : Authorization.Prompt) :
    Authorization.Decision :=
  let ticked (scope : Authorization.Scope) : Bool := (params.get (approvalField scope)).isSome
  if params.get "decision" == some "allow" then
    .granted prompt (prompt.requestedScopes.filter ticked)
  else
    .denied prompt

/-- The authorization endpoint, and the consent page that hangs off it.

Both methods are the one route, and deliberately: the form posts back to the URL it was served
from, so what `conclude` acts on is the request as it arrived rather than a copy of it
reassembled out of hidden fields. Running `authorize` again on the way through is what re-reads
it, and costs a client lookup that is cached.

Unlike every other route a browser reaches, this one is not behind `guarded`. Whether a request
with no session should sign somebody in, refuse, or redirect an error to the client is the
authorization server's answer to give, and `prompt=none` is a case where sending the browser to
a sign-in page would be wrong. -/
def authorizeHandler (site : Authorization.Site) (params : Params)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let session := (req.extensions.get Cookies).bind (·.get Auth.sessionCookie)
  -- What a client asked for, said out loud. An agent that reaches the end of this flow holding a
  -- token that names no scope arrives at the MCP endpoint to find no tools and nothing to read,
  -- and the request that decided it is not otherwise recorded anywhere: spans carry the route,
  -- not the query.
  (Telemetry.info "authorization requested"
    [ ("oauth.scope_requested",
        .str ((queryParams params |>.find? (·.1 == "scope")).map (·.2) |>.getD "<absent>")) ]
    : TelemetryT Async Unit).run (parentSpan req)
  settle req
    (fun prompt => do
      if req.line.method == .post then
        -- `conclude` answers with a redirect or a refusal and never asks again, so reaching the
        -- consent branch here would mean the library had changed under this code.
        settle req (fun _ => refusedClientPage "" |> Response.internalServerError.html)
          (← (site.conclude (decisionFor params prompt) : IO _))
      else
        consentPage prompt (target req) ((req.extensions.get AntiForgeryToken).map (·.value))
          |> Response.ok.html)
    (← (site.authorize (queryParams params) session : IO _))

def tokenHandler (site : Authorization.Site) (params : Params)
    (_req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  match ← (site.token (formParams params) : IO _) with
  | .ok tokens => jsonResponse 200 tokens.toJson
  | .error refusal => refused refusal

/-- Registration takes JSON where the token endpoint takes a form, which is the protocol's doing
rather than an inconsistency to smooth over: a parser that accepted either would accept a
form-encoded registration, and this server has agreed to read no such thing. -/
def registerHandler (site : Authorization.Site) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let body ← MCP.StdHttp.collect req.body
  match Json.parse (String.fromUTF8? body |>.getD "") with
  | .error _ =>
    refused { error := .invalidClientMetadata, description := "the request body is not JSON" }
  | .ok document =>
    let (status, answer) ← (site.register document : IO _)
    jsonResponse status answer

/-! ## The endpoint an outside agent reaches -/

/-- A refusal that says where to go and ask for a token, which is the whole of how an agent
holding nothing finds its way in: RFC 9728 puts the resource's own metadata document behind
`resource_metadata`, and that document names the authorization server. -/
private def refuse (site : Authorization.Site) (rejection : Authorization.Rejection) :
    ContextAsync (Response Body.Any) := do
  let (status, challenge) := site.challenge rejection
  let response ← Response.withStatus (statusOf status) |>.text "Unauthorized"
  pure (withHeader response (Header.Name.mk "www-authenticate") challenge)

/-- Every tool the panel's model has, offered to whatever agent the person brought, as whoever
granted the token it presents and narrowed to what they granted.

Unlike the browser routes, this one is reached with no session and no anti-forgery token: an
agent holds a token rather than a cookie, which is why `Todo.server` keeps it outside the
middleware that requires one. -/
def mcpHandler (store : Store) (site : Authorization.Site) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let presented := (req.line.headers.getLast? (Header.Name.mk "authorization")).map toString
  let some credential := Authorization.bearer? presented
    | do
      (Telemetry.info "mcp call carried no bearer token" [] : TelemetryT Async Unit).run
        (parentSpan req)
      refuse site .unknown
  match ← (site.verify credential : IO _) with
  | .error rejection =>
    (Telemetry.info "mcp token refused" [] : TelemetryT Async Unit).run (parentSpan req)
    refuse site rejection
  | .ok claims =>
    -- A token that reaches no tool is refused rather than served an empty list. Serving one is
    -- indistinguishable from a server with nothing on it, so a client holding a grant made
    -- before it knew what to ask for has no way to learn that it should ask again; the challenge
    -- names the scopes it wants, which is what a client comes back for.
    if (Mcp.permitted claims.scopes).isEmpty then
      (Telemetry.info "mcp token holds no usable scope" [] : TelemetryT Async Unit).run
        (parentSpan req)
      refuse site (.insufficientScope Authorization.scopes)
    else do
      (Telemetry.info "mcp call authorized"
        [("oauth.scope_held", .str (String.intercalate " " (claims.scopes.map (·.value))))]
        : TelemetryT Async Unit).run (parentSpan req)
      let bytes ← MCP.StdHttp.collect req.body
      let served ← (MCP.serve Mcp.config (Mcp.server store claims.scopes) claims.account
        (MCP.StdHttp.requestOf req.line bytes)).run (parentSpan req)
      MCP.StdHttp.responseOf served

/-! ## The router -/

/-- Everything below needs to know who is asking, so establishing it is the router's job rather
than each handler's. A request with no live session never reaches one. -/
private def guarded (identity : Identity)
    (handler : Account → Request Body.Stream → ContextAsync (Response Body.Any)) :
    Request Body.Stream → ContextAsync (Response Body.Any) := fun req => do
  match ← (identity.of req : IO _) with
  | some account => handler account req
  | none => toSignIn req

/-- Hands a handler what was parsed, rather than leaving it to ask.

`params` runs in front of every route, so a request arriving without it is a stack assembled
wrongly and not a request that carried nothing. Read out of the extension, those are the same
`none`: a handler cannot tell a form it never parsed from a form with nothing in it, and answers
as though the field were absent. Which is silent, and wrong in whichever direction the field
mattered. -/
private def withParams
    (handler : Params → Request Body.Stream → ContextAsync (Response Body.Any)) :
    Request Body.Stream → ContextAsync (Response Body.Any) := fun req =>
  match req.extensions.get Params with
  | some params => handler params req
  | none => "nothing parsed this request's parameters" |> Response.internalServerError.text

def app (identity : Identity) (store : Store) (assistant : Assistant)
    (authorization : Authorization.Site) : StatelessHandler :=
  let byId (handler : Store → Account → Nat → Request Body.Stream →
      ContextAsync (Response Body.Any)) := fun id =>
    guarded identity (handler store · id ·)
  toHandler [
    .get patterns.index (guarded identity (pageHandler .all store assistant identity)),
    .get patterns.active (guarded identity (pageHandler .active store assistant identity)),
    .get patterns.completed (guarded identity (pageHandler .completed store assistant identity)),
    .post patterns.todos (guarded identity fun account => withParams (addHandler store account)),
    .get patterns.todosStatus
      (guarded identity fun account => withParams (listStatusHandler store account)),
    .get patterns.edit (byId editHandler),
    .put patterns.todo (fun id =>
      guarded identity fun account => withParams (saveHandler store account id)),
    .post patterns.toggle (byId toggleHandler),
    .delete patterns.todo (byId deleteHandler),
    .post patterns.toggleAll (guarded identity (toggleAllHandler store)),
    .delete patterns.clearCompleted (guarded identity (clearCompletedHandler store)),
    .post patterns.signOut (guarded identity (signOutHandler identity)),
    .get patterns.connect (guarded identity (connectHandler authorization)),
    .post patterns.disconnect (guarded identity (disconnectHandler authorization)),
    .post patterns.chat
      (guarded identity fun account => withParams (chatHandler store assistant account)),
    .get patterns.chatStatus
      (guarded identity fun account => withParams (chatStatusHandler store assistant account)),
    .delete patterns.chat (guarded identity (chatResetHandler assistant)),
    -- Here rather than beside the machine-facing endpoints because this is the one a person
    -- answers, and answering it has to be protected from another site posting the answer.
    .get patterns.oauthAuthorize (withParams (authorizeHandler authorization)),
    .post patterns.oauthAuthorize (withParams (authorizeHandler authorization))
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

/-- The endpoints a client reaches rather than a browser, served beside the application for the
reason the sign-in routes are: they answer requests that carry no session, and `antiForgery`
refuses those. The two metadata documents are here because they answer with no session either,
and everything inside the application redirects a request without one to the sign-in page.

The authorization endpoint is the exception and stays inside, because a person answers it. -/
private def underClient (req : Request Body.Stream) : Bool :=
  match req.line.uri.path.toDecodedSegments.toList with
  | ["mcp"] | ["oauth", "token"] | ["oauth", "register"] => true
  | [".well-known", "oauth-authorization-server"] => true
  | [".well-known", "oauth-protected-resource"] => true
  | [".well-known", "oauth-protected-resource", "mcp"] => true
  | _ => false

private def split (auth client application : StatelessHandler) : StatelessHandler :=
  { onRequest := fun req =>
      if underAuth req then auth.onRequest req
      else if underClient req then client.onRequest req
      else application.onRequest req }

/-- The routes wrapped in the middleware stack recommended for a browser-facing site, in
`Middleware.apply`'s documented order.

`https` states whether something in front of this server terminates TLS, which is the only thing
that can establish it: `Std.Http.Server` serves plain http either way. Setting it marks the
session cookie `secure` and sends `hsts`. Claiming it falsely is the damaging direction, since a
`secure` cookie would never come back and `antiForgery` would then reject every mutation.

`sslRedirect` is absent whichever way `https` goes, because neither deployment has a plaintext
listener to redirect a caller away from. -/
def server [SessionStore σ] (identity : Identity) (auth : StatelessHandler) (store : Store)
    (assistant : Assistant) (sessions : σ) (authorization : Authorization.Site)
    (https : Bool := false) : StatelessHandler :=
  let client := toHandler
    [ .post patterns.mcp (mcpHandler store authorization),
      .get patterns.mcp (mcpHandler store authorization),
      .delete patterns.mcp (mcpHandler store authorization),
      .post patterns.oauthToken (withParams (tokenHandler authorization)),
      .post patterns.oauthRegister (registerHandler authorization),
      .get patterns.oauthMetadata (metadataHandler authorization),
      .get patterns.mcpMetadata (resourceMetadataHandler authorization),
      -- RFC 9728 §3 puts the resource's own path into the well-known URL, and that is the form a
      -- client tries first. Both are served because a client that tried only the shorter one
      -- would otherwise have nothing to read.
      .get patterns.mcpMetadataForEndpoint (resourceMetadataHandler authorization) ]
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
    (split auth client
      (Middleware.apply [antiForgery] (app identity store assistant authorization)))

end Todo
