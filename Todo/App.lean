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
public import Todo.AccountViews
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

The one reader left that takes its parameters from the extension rather than `Extract.params`,
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

def pageHandler (assets : Assets) (filter : Filter) (store : Store) (assistant : Assistant) (identity : Identity)
    (account : Account) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let address ← (identity.address account : IO _)
  let parent := parentSpan req
  let messages ← (assistant.chat.history account).run parent
  -- A reload during a turn rejoins it rather than showing a conversation that stops mid-question:
  -- the panel comes back polling, exactly as the request that started the turn left it.
  let turn ← (assistant.turns.get account : IO _)
  render store account parent filter
    (pageView assets ((req.extensions.get AntiForgeryToken).map (·.value)) address messages turn)

/-- Swaps one todo's `<li>` into edit mode. Not a mutation (nothing in the store changes), so
unlike every other route below it targets and returns just that one item, not the whole list
section. -/
def editHandler (store : Store) (account : Account) (id : Nat) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let items ← (store.list account .all).run (parentSpan req)
  match items.find? (fun item => item.id == Int64.ofNat id) with
  | some item => Node.render (itemEditView item) |> Response.ok.html
  | none => "Not Found" |> Response.notFound.text

/-- How many of the turn's mutations the fragment that sent this poll was drawn against. Missing
or unreadable reads as none, which costs a redundant refresh rather than a missed one. -/
def seenCount : Extractor Nat := (fun seen => (seen.bind (·.toNat?)).getD 0) <$> Extract.field? "seen"

def addHandler (store : Store) (account : Account) (title : String)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  (store.add account title).run (parentSpan req)
  renderMutation store account req

def saveHandler (store : Store) (account : Account) (id : Nat) (title : String)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  (store.setTitle account (Int64.ofNat id) title).run (parentSpan req)
  renderMutation store account req

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
def seenDigest : Extractor String := (·.getD "") <$> Extract.field? "seen"

/-- Answers the page's standing question of whether the list it is showing is still the list the
store holds, and says nothing at all when it is.

This is what makes a change the browser did not make visible: an agent reaching the tools over
MCP, the assistant panel in another tab, or the same account on a phone. Nothing else asks, since
the assistant's own poll runs only while a turn is in flight.

Answering with the list only when the digest has moved is not an optimisation. An unprompted swap
discards a todo somebody is part-way through editing inline, so a poll that refreshed on every
tick would make inline editing impossible to finish. -/
def listStatusHandler (store : Store) (account : Account) (seen : String)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let parent := parentSpan req
  let allItems ← (store.list account .all).run parent
  if listDigest allItems == seen then
    "" |> Response.ok.html
  else
    let filter := currentFilter req
    let items ← (store.list account filter).run parent
    listRefreshFragment items allItems filter |> Response.ok.html

/-- The address of the MCP endpoint, and what to hand an assistant of your own so that it can
set itself up against it. Behind the session like the rest of the application, though nothing on
it is private: what it describes is this account's list, and somebody reading it has one. -/
private def connectView (assets : Assets) (authorization : Authorization.Site) (account : Account)
    (req : Request Body.Stream) (withdrew : Option Withdrawal := none) :
    ContextAsync (Response Body.Any) := do
  -- Read after any withdrawal rather than before, so the page shows what is connected now and
  -- not what was connected when the button was pressed.
  let connections ← (authorization.connections account : IO _)
  connectPage assets authorization.endpoint ((req.extensions.get AntiForgeryToken).map (·.value))
    connections withdrew |> Response.ok.html

def connectHandler (assets : Assets) (authorization : Authorization.Site) (account : Account)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  connectView assets authorization account req

/-- Withdraws every approval this account has given, and says so on the page it was asked from.

The page rather than a redirect because there is nothing to carry a message through one, and
answering the `POST` costs only a resubmission on refresh, which withdraws what is already
withdrawn. -/
def disconnectHandler (assets : Assets) (authorization : Authorization.Site) (account : Account)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let revoked ← (authorization.disconnect account : IO Nat)
  (Telemetry.info "every agent disconnected" [("oauth.connections_revoked", .int revoked)]
    : TelemetryT Async Unit).run (parentSpan req)
  connectView assets authorization account req (some (.all revoked))

/-- Withdraws the one approval the row named.

Both fields are required and neither has a default. A missing `client` cannot be read as "all of
them": that is the same request as the button beside this one, and a form that lost a hidden
field would then withdraw everything somebody still wanted. -/
def disconnectOneHandler (assets : Assets) (authorization : Authorization.Site) (account : Account)
    (client? resource? : Option String) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  match client?, resource? with
  | some client, some resource => do
    -- The name is read before the withdrawal, since afterwards there is no row left to read it
    -- from and the page has to say which one went.
    let name := (← (authorization.connections account : IO _)).find?
      (fun c => c.client.value == client && c.resource.value == resource)
      |>.bind (·.clientName) |>.getD "that assistant"
    let withdrawn ← (authorization.revoke account client resource : IO Bool)
    (Telemetry.info "one agent disconnected"
      [("oauth.client", .str client), ("oauth.resource", .str resource),
       ("oauth.was_connected", .str (if withdrawn then "yes" else "no"))]
      : TelemetryT Async Unit).run (parentSpan req)
    connectView assets authorization account req
      (some (if withdrawn then .one name else .alreadyGone))
  | _, _ =>
    (Telemetry.info "one agent disconnect named nothing"
      [("oauth.client_named", .str (if client?.isSome then "yes" else "no")),
       ("oauth.resource_named", .str (if resource?.isSome then "yes" else "no"))]
      : TelemetryT Async Unit).run (parentSpan req)
    "Missing client or resource" |> Response.badRequest.text

/-- What can get into this account, and the controls that change it.

Read after any change rather than before, for the reason the connect page is: the page has to show
what is linked now and not what was linked when the button was pressed. -/
private def accountView (assets : Assets) (identity : Identity)
    (providers : List Authentication.ProviderConfig) (account : Account)
    (req : Request Body.Stream) (notice : Option AccountNotice := none) :
    ContextAsync (Response Body.Any) := do
  let address ← (identity.address account : IO _)
  let linked ← (identity.linked account : IO _)
  accountPage assets address providers linked ((req.extensions.get AntiForgeryToken).map (·.value)) notice
    |> Response.ok.html

def accountHandler (assets : Assets) (identity : Identity) (providers : List Authentication.ProviderConfig)
    (account : Account) (req : Request Body.Stream) : ContextAsync (Response Body.Any) :=
  accountView assets identity providers account req

/-- Takes one provider away from this account.

A credential that is not this account's and one that never existed are the same answer, which is
the library's choice repeated here: telling them apart would let somebody guessing identifiers
learn which ones are real.

The name is read before the removal, because afterwards there is no credential left to read it
from and the page has to say which one went. -/
def accountUnlinkHandler (assets : Assets) (identity : Identity)
    (providers : List Authentication.ProviderConfig) (account : Account) (credential? : Option String)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  match credential? with
  | none =>
    (Telemetry.info "unlink named no credential" [] : TelemetryT Async Unit).run (parentSpan req)
    "Missing credential" |> Response.badRequest.text
  | some raw =>
    let name := (← (identity.linked account : IO _)).find? (·.id.value == raw)
      |>.bind (fun credential =>
        match credential.descriptor with
        | .federatedIdentity identity =>
          (providers.find? (·.issuer == identity.issuer)).map (Todo.Federation.label ·.id)
        | .emailAddress _ | .passkey _ => none)
      |>.getD "that provider"
    let outcome ← (identity.unlink account ⟨raw⟩ : IO _)
    let notice : AccountNotice := match outcome with
      | .ok () => .disconnected name
      | .error .lastWayIn => .lastWayIn
      | .error .notThisAccount => .alreadyGone
    (Telemetry.info "identity unlink"
      [("auth.provider", .str name),
       ("auth.outcome", .str (match outcome with
         | .ok () => "unlinked"
         | .error .lastWayIn => "refused, last way in"
         | .error .notThisAccount => "not this account"))]
      : TelemetryT Async Unit).run (parentSpan req)
    accountView assets identity providers account req (some notice)

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
      headers := response.line.headers.insert Std.Http.Header.Name.setCookie cleared } }
    (Header.Name.mk "hx-redirect") signInPath)

/-! ## The assistant panel -/

def prompt : Extractor (Option String) :=
  (fun raw => raw.map (·.trimAscii.toString) |>.filter (!·.isEmpty)) <$> Extract.field? "prompt"

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
    (prompt : Option String) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  let parent := parentSpan req
  if let some prompt := prompt then
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
    (seen : Nat) (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
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
  let moved := turn.any (·.mutations > seen)
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

/-- What a client that was refused at the MCP endpoint follows to find out where to ask for a
token. -/
def resourceMetadataHandler (site : Authorization.Site) (_req : Request Body.Stream) :
    ContextAsync (Response Body.Any) :=
  jsonResponse 200 site.resourceMetadata


/-! ## The endpoint an outside agent reaches -/

/-- A refusal that says where to go and ask for a token, which is the whole of how an agent
holding nothing finds its way in: RFC 9728 puts the resource's own metadata document behind
`resource_metadata`, and that document names the authorization server.

Said twice, in the header and in the body, because the header does not always survive the way
out. What a refusal costs when it says nothing is a client that reconnects forever against a
grant it cannot know is wrong. -/
private def refuse (site : Authorization.Site) (rejection : Authorization.Rejection) :
    ContextAsync (Response Body.Any) := do
  let challenge := site.challenge rejection
  let response ← jsonResponse challenge.status challenge.document
  pure (withHeader response (Header.Name.mk "www-authenticate") challenge.header)

/-- Every tool the panel's model has, offered to whatever agent the person brought, as whoever
granted the token it presents and narrowed to what they granted.

Unlike the browser routes, this one is reached with no session and no anti-forgery token: an
agent holds a token rather than a cookie, which is why `Todo.server` keeps it outside the
middleware that requires one. -/
def mcpHandler (store : Store) (site : Authorization.Site) (req : Request Body.Stream) :
    ContextAsync (Response Body.Any) := do
  let presented := (req.line.headers.getLast? (Header.Name.mk "authorization")).map toString
  let some credential := MCP.bearer? presented
    | do
      (Telemetry.info "mcp call carried no bearer token" [] : TelemetryT Async Unit).run
        (parentSpan req)
      refuse site .unknown
  match ← (site.verify credential : IO _) with
  | .error rejection =>
    (Telemetry.info "mcp token refused" [("oauth.rejection", .str rejection.name)]
      : TelemetryT Async Unit).run (parentSpan req)
    refuse site rejection
  | .ok claims =>
    -- A token that reaches no tool is refused rather than served an empty list. Serving one is
    -- indistinguishable from a server with nothing on it, so a client holding a grant made
    -- before it knew what to ask for has no way to learn that it should ask again; the challenge
    -- names the scopes it wants, which is what a client comes back for.
    if (Mcp.permitted claims.scopes).isEmpty then
      -- Spelled rather than left empty: a token carrying no scopes at all is the common way to
      -- reach this, and an empty attribute reads as one that was never recorded.
      let held := if claims.scopes.isEmpty then "none"
        else Authentication.OAuth.Scope.render claims.scopes
      (Telemetry.info "mcp token holds no usable scope" [("oauth.scopes_held", .str held)]
        : TelemetryT Async Unit).run (parentSpan req)
      refuse site (.insufficientScope Authorization.scopes)
    else do
      let bytes ← MCP.StdHttp.collect req.body
      let served ← (MCP.serve Mcp.config (Mcp.server store claims.scopes) claims.account
        (MCP.StdHttp.requestOf req.line bytes)).run (parentSpan req)
      MCP.StdHttp.responseOf served

/-! ## The router -/

/-- Who is asking. Every application route needs to know, so establishing it is the router's job
rather than each handler's, and a request with no live session never reaches one. -/
private def signedIn (identity : Identity) : Extractor Account := do
  let req ← read
  match ← (identity.of req : IO _) with
  | some account => pure account
  | none => Extract.refuse (toSignIn req)

/-- The application's own routes. The account is extracted before anything else, so a request
with no session is sent to sign in rather than refused for a field it could not have filled. -/
def appRoutes (assets : Assets) (identity : Identity) (store : Store) (assistant : Assistant)
    (authorization : Authorization.Site)
    (oauth : List (Routing.Route Routing.Result) := [])
    (providers : List Authentication.ProviderConfig := []) : List Entry :=
  let page (filter : Filter) := extract (a ← signedIn identity) =>
    pageHandler assets filter store assistant identity a
  let byId (handler : Store → Account → Nat → Request Body.Stream →
      ContextAsync (Response Body.Any)) (id : Nat) :=
    extract (a ← signedIn identity) => handler store a id
  [ .get patterns.index (page .all),
    .get patterns.active (page .active),
    .get patterns.completed (page .completed),
    .post patterns.todos (extract (a ← signedIn identity) (title ← Extract.field "title") =>
      addHandler store a title),
    .get patterns.todosStatus (extract (a ← signedIn identity) (seen ← seenDigest) =>
      listStatusHandler store a seen),
    .get patterns.edit (byId editHandler),
    .put patterns.todo fun id => extract (a ← signedIn identity) (title ← Extract.field "title") =>
      saveHandler store a id title,
    .post patterns.toggle (byId toggleHandler),
    .delete patterns.todo (byId deleteHandler),
    .post patterns.toggleAll (extract (a ← signedIn identity) => toggleAllHandler store a),
    .delete patterns.clearCompleted (extract (a ← signedIn identity) => clearCompletedHandler store a),
    .post patterns.signOut (extract (a ← signedIn identity) => signOutHandler identity a),
    .get patterns.account (extract (a ← signedIn identity) =>
      accountHandler assets identity providers a),
    .post patterns.accountUnlink
      (extract (a ← signedIn identity) (credential ← Extract.field? "credential") =>
        accountUnlinkHandler assets identity providers a credential),
    .get patterns.connect (extract (a ← signedIn identity) => connectHandler assets authorization a),
    .post patterns.disconnect (extract (a ← signedIn identity) =>
      disconnectHandler assets authorization a),
    .post patterns.disconnectOne
      (extract (a ← signedIn identity) (client ← Extract.field? "client")
          (resource ← Extract.field? "resource") =>
        disconnectOneHandler assets authorization a client resource),
    .post patterns.chat (extract (a ← signedIn identity) (p ← prompt) =>
      chatHandler store assistant a p),
    .get patterns.chatStatus (extract (a ← signedIn identity) (seen ← seenCount) =>
      chatStatusHandler store assistant a seen),
    .delete patterns.chat (extract (a ← signedIn identity) => chatResetHandler assistant a)
  ] ++ oauth.map .route

def app (assets : Assets) (identity : Identity) (store : Store) (assistant : Assistant)
    (authorization : Authorization.Site)
    (oauth : List (Routing.Route Routing.Result) := [])
    (providers : List Authentication.ProviderConfig := []) : StatelessHandler :=
  ({ routes := appRoutes assets identity store assistant authorization oauth providers } : Router)
    |>.toHandler

/-- Where the sign-in routes answer, which is also where the mail they send points. -/
private def tenantRoot : MountPoint := .mk ["t", Todo.tenant.value]

/-- The routes wrapped in the middleware stack recommended for a browser-facing site, in
`Middleware.apply`'s documented order.

`https` states whether something in front of this server terminates TLS, which is the only thing
that can establish it: `Std.Http.Server` serves plain http either way. Setting it marks the
session cookie `secure` and sends `hsts`. Claiming it falsely is the damaging direction, since a
`secure` cookie would never come back and `antiForgery` would then reject every mutation.

`sslRedirect` is absent whichever way `https` goes, because neither deployment has a plaintext
listener to redirect a caller away from.

`assets` serves everything under `public` at a path carrying the digest of its content, and is
the only reason a far-future policy on those paths is safe. `cacheControl` covers everything
else: a response carrying validators and no freshness directive falls to heuristic freshness, so
the browser stops asking and `notModified` is never reached, which is how a redeployed
stylesheet went on being ignored. `file` serves the unfingerprinted paths, which older pages still
name. Both answer whatever no route takes, with no session, since a stylesheet has no use for one.

`cookies` and `session` sit outside `notModified`, because a `304` keeps only the validators and
the freshness headers, so a `Set-Cookie` written inside it would never reach the browser.

Only the application's own routes are behind `antiForgery`. The sign-in routes carry an
anti-forgery token of their own, derived from the attempt cookie under the server's pepper, and the
browser reaching them has no session for `antiForgery` to have put one in. They read and write
their own cookies, so they have no `session` either. `auth` takes everything under the tenant's
prefix, its misses included, since the library answers those with a page of its own. The endpoints
a client reaches have no session at all: an agent holds a token rather than a cookie, and the
resource's metadata document answers anybody.

`oauth` is the authorisation server's own endpoints, already split by the library into the half a
person answers and the half a client does. The halves land on opposite sides of `antiForgery`,
which is the whole reason they arrive as two lists: one wrapper over both would leave either a
consent form that cannot be posted or a token endpoint that refuses every client. -/
def server [SessionStore σ] (assets : Assets) (identity : Identity) (auth : StatelessHandler)
    (store : Store) (assistant : Assistant) (sessions : σ) (authorization : Authorization.Site)
    (oauth : Authentication.OAuth.Http.Routes := { browser := [], client := [] })
    (providers : List Authentication.ProviderConfig := [])
    (https : Bool := false) : StatelessHandler :=
  let client : List Entry :=
    [ .post patterns.mcp (mcpHandler store authorization),
      .get patterns.mcp (mcpHandler store authorization),
      .delete patterns.mcp (mcpHandler store authorization),
      .get patterns.mcpMetadata (resourceMetadataHandler authorization),
      -- RFC 9728 §3 puts the resource's own path into the well-known URL, and that is the form a
      -- client tries first. Both are served because a client that tried only the shorter one
      -- would otherwise have nothing to read.
      .get patterns.mcpMetadataForEndpoint (resourceMetadataHandler authorization) ]
    ++ oauth.client.map .route
  let browser :=
    [cookies,
     session sessions
       { cookieName := "todomvc-session",
         cookieAttrs := { path := some "/", httpOnly := true, sameSite := some .lax,
                          secure := https } }]
  let content := [params, contentType, defaultCharset, cacheControl .noCache, notModified]
  let root : Router :=
    { middlewares := [forwardedScheme, forwardedRemoteAddr]
        ++ (if https then [hsts] else [])
        ++ [xFrameOptions .sameOrigin, xContentTypeOptions,
            catchAll,
            serverSpan matchedPattern?],
      routers := [
        { middlewares := content, routes := [.mount tenantRoot []], fallback := some auth },
        { middlewares := content, routes := client },
        { middlewares := browser ++ content ++ [antiForgery],
          routes := appRoutes assets identity store assistant authorization oauth.browser
            providers } ],
      fallback := some (Middleware.apply
        (content ++ [Middleware.assets assets.served, file "public"]) (toHandler [])) }
  root.toHandler

end Todo
