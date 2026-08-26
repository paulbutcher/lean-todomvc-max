/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.App
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Std.Async (Async)
open Std.Http.Internal.Test
open Std Http Server
open Telemetry (runTelemetry)
open Routes

/-! ## The endpoint an outside agent reaches

What the protocol does with a request is `lean-mcp`'s to answer for, and what a token means is
`lean-authentication`'s. What is checked here is this application between them: that a request
carrying nothing is told where to go, that a token reaches only the tools its scopes name and
only the list its account owns, and that none of the middleware standing in front of the browser
routes stands in front of any of this. -/

private def readOnly : String := "read-only-token"
private def fullAccess : String := "full-access-token"

private def issued : List (String × Account × List Authorization.Scope) :=
  [ (readOnly, alice, [Authorization.read]),
    (fullAccess, alice, [Authorization.read, Authorization.write]) ]

private def authorization : Authorization.Site := scriptedAuthorization testBase issued

/-- The whole stack, not just the handler: the point of several of these is that a request
carrying no session and no anti-forgery token gets through it, which only the real middleware can
demonstrate. -/
private def siteOf (store : Store) (site : Authorization.Site := authorization) :
    IO TestHandler := do
  let assistant ← scriptedAssistant #[]
  let sessions ← Middleware.MemoryStore.new
  let auth : StatelessHandler :=
    { onRequest := fun _ => "no sign-in here" |> Response.notFound.text }
  pure (Todo.server (fixedIdentity alice (← IO.mkRef 0)) auth store assistant sessions
    site).onRequest

private def call (body : String) (credential : Option String := some s!"Bearer {fullAccess}") :
    String :=
  let authorization := match credential with
    | some value => s!"Authorization: {value}\x0d\n"
    | none => ""
  mkPost "/mcp" body
    ("Content-Type: application/json\x0d\nMCP-Protocol-Version: 2025-11-25\x0d\n" ++
      authorization ++ "Connection: close\x0d\n")

private def rpc (id : Nat) (method : String) (params : Json) : String :=
  Json.compress (Json.mkObj
    [("jsonrpc", "2.0"), ("id", Json.ofNat id), ("method", method), ("params", params)])

private def listTools : String := rpc 1 "tools/list" (Json.mkObj [])

private def callTool (name : String) (arguments : List (String × Json)) : String :=
  rpc 2 "tools/call" (Json.mkObj [("name", name), ("arguments", Json.mkObj arguments)])

private def titlesOf (store : Store) (account : Account := alice) : IO (Array String) := do
  let items ← Async.block (runTelemetry (store.list account .all))
  pure (items.map (·.title))

/-! ## Finding the way in -/

/-- An agent holding nothing has to be able to get from a refusal to a token, and the chain that
lets it is this: the challenge names the protected resource metadata document, that document
names the authorization server, and that server's own document names the endpoints.

Broken anywhere along it, an agent has no way to discover this server at all, and each link is a
different file's doing. -/
private def testAnAgentHoldingNothingCanFindTheWayIn : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "a call with no credential" (call listTools none) handler fun response => do
    assertStatus response "HTTP/1.1 401"
    assertContains response (Authorization.metadataUrl testBase)
  check "the document it names" (mkGetClose links.mcpMetadata) handler fun response => do
    assertStatus response "HTTP/1.1 200"
    assertContains response (Authorization.resource testBase).value
    assertContains response (Authorization.config testBase).issuer
  check "and the server that document names" (mkGetClose links.oauthMetadata) handler
    fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response (Authorization.config testBase).authorizationEndpoint
      assertContains response (Authorization.config testBase).tokenEndpoint
      -- A client that cannot find PKCE advertised must refuse to proceed, so its absence would
      -- turn every agent away at the first step.
      assertContains response "S256"

/-- A request that names no scopes asks for everything on offer, rather than for nothing.

Asking for nothing is answered without a consent page, because there is nothing to put on one,
and the token it ends in reaches no tool at all. The client sees a connection with no tools on
it, which is the one failure that says nothing about itself. -/
private def testAClientThatNamesNoScopesAsksForEverything : IO Unit := do
  let named := Authorization.withDefaultScopes [("client_id", "x"), ("scope", "todos:read")]
  let unnamed := Authorization.withDefaultScopes [("client_id", "x")]
  checkEq "a request that named one keeps it" (some "todos:read")
    ((named.find? (·.1 == "scope")).map (·.2))
  checkEq "and one that named none is read as asking for all of them"
    (some (String.intercalate " " (Authorization.scopes.map (·.value))))
    ((unnamed.find? (·.1 == "scope")).map (·.2))

/-- What the document offers and what the server will do have to agree.

Nothing here fetches a client's metadata document, so a client told it may use a URL as its
identifier is told to take the one path that ends in a refusal, and it believes the document
rather than trying the other way afterwards. What it costs to get this wrong is every client that
prefers that mechanism, which is not a small set. -/
private def testTheServerOffersNoWayInThatEndsInARefusal : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "the authorization server's own document" (mkGetClose links.oauthMetadata) handler
    fun response => do
      assertContains response "\"client_id_metadata_document_supported\":false"
      -- The way in that is left, which has to still be there for the withdrawal to be safe.
      assertContains response (Authorization.config testBase).registrationEndpoint

/-- Both documents answer whoever asks. They are what a client reads before it has anything to
present, so a refusal here is a client that can never get started. -/
private def testDiscoveryNeedsNoCredential : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  for path in [links.mcpMetadata, links.oauthMetadata] do
    check s!"GET {path} with nothing at all" (mkGetClose path) handler fun response =>
      assertStatus response "HTTP/1.1 200"

/-! ## What a token admits -/

/-- Without a token nothing runs, and a token nobody issued is refused the same way as none at
all. -/
private def testATokenIsRequired : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "no Authorization header" (call (callTool "add_todo" [("title", "gamma")]) none) handler
    fun response => do
      assertStatus response "HTTP/1.1 401"
      -- The scheme, not the header name, which the server is free to re-case.
      assertContains response "Bearer"
  check "a token nobody issued"
    (call (callTool "add_todo" [("title", "delta")]) (some "Bearer wrong")) handler
    fun response => assertStatus response "HTTP/1.1 401"
  checkEq "and neither of them reached the store" #[] (← titlesOf store)

/-- Every tool the panel's model is offered is offered here too, because both come from the one
registry. Stated over the registry rather than a list written out again, so a tool added to it is
covered without this test being touched. -/
private def testAFullTokenReachesEveryTool : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "tools/list" (call listTools) handler fun response => do
    assertStatus response "HTTP/1.1 200"
    for entry in ChatTools.registry do
      assertContains response entry.tool.name

/-- A read-only grant is offered the tools it can use and not the ones it cannot, rather than
being told about a tool and turned away from calling it.

Both halves matter: a catalogue that showed everything would have the agent plan around a tool
that refuses, and one that showed nothing would make the grant useless. -/
private def testAReadOnlyTokenReachesOnlyTheReadingTools : IO Unit := do
  let store ← memoryStore alice #[{ id := 1, title := "alpha", completed := false }]
  let handler ← siteOf store
  check "tools/list with a read-only token" (call listTools (some s!"Bearer {readOnly}")) handler
    fun response => do
      assertStatus response "HTTP/1.1 200"
      for entry in ChatTools.registry do
        if entry.mutates then assertAbsent response entry.tool.name
        else assertContains response entry.tool.name

/-- The scope is what stops the call, not just what hides the tool. An agent that knows the name
from a fuller grant, or guesses it, gets nowhere with it. -/
private def testAReadOnlyTokenCannotChangeAnything : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "add_todo with a read-only token"
    (call (callTool "add_todo" [("title", "gamma")]) (some s!"Bearer {readOnly}")) handler
    fun response => assertAbsent response "gamma"
  checkEq "nothing was added" #[] (← titlesOf store)

/-- The call reaches the store, as the account the token names and no other.

This is also what shows the endpoint standing outside the middleware the browser routes sit
behind: the request carries no session cookie and no anti-forgery token, and `antiForgery` would
refuse a POST that carried neither. -/
private def testCallsReachTheStoreAsTheTokensAccount : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "tools/call add_todo" (call (callTool "add_todo" [("title", "gamma")])) handler
    fun response => assertStatus response "HTTP/1.1 200"
  checkEq "the todo is alice's" #["gamma"] (← titlesOf store)
  checkEq "and nobody else's" #[] (← titlesOf store bob)

/-! ## Reading an authorization request -/

/-- A parameter sent twice is `invalid_request`, which the authorisation server can only say if
it is told the parameter arrived twice. A reader that kept the first would quietly accept a
request the specification refuses, in exactly the case somebody is trying something. -/
private def testDuplicatedParametersSurviveBeingRead : IO Unit := do
  let query := (URI.Query.empty.insert "resource" "https://one.example").insert
    "client_id" "https://client.example"
  let doubled := query.insertEncoded (URI.EncodedQueryParam.encode "resource")
    (some (URI.EncodedQueryParam.encode "https://two.example"))
  checkEq "one of each is read as one of each" 2 (Authorization.params query).length
  checkEq "and a repeat is read as a repeat" 3 (Authorization.params doubled).length
  checkEq "with the values it was sent"
    ["https://one.example", "https://two.example"]
    ((Authorization.params doubled).filterMap fun (name, value) =>
      if name == "resource" then some value else none)

/-! ## Asking the person -/

private def someClient : Authentication.OAuth.Client :=
  { id := ⟨"https://agent.example/metadata"⟩
    metadata :=
      { clientName := "Some Agent", redirectUris := ["https://agent.example/callback"] }
    origin := .metadataDocument }

private def somePrompt (loopbackOnly : Bool := false) : Authorization.Prompt :=
  { request :=
      { clientId := someClient.id, redirectUri := "https://agent.example/callback",
        redirectUriGiven := true, state := some "opaque",
        scopes := [Authorization.read, Authorization.write], codeChallenge := "challenge",
        resource := Authorization.resource testBase, prompt := [], maxAge := none }
    account := alice
    client := someClient
    clientHost := some "agent.example"
    redirectHost := "agent.example"
    loopbackOnly
    resource := Authorization.resource testBase
    requestedScopes := [Authorization.read, Authorization.write]
    grantedScopes := [] }

/-- Everything the MCP authorization specification requires be displayed is displayed, and the
name the client gave itself is never the only thing shown: a name is a string it chose, and the
host beside it is not. -/
private def testTheConsentPageSaysWhoIsAskingAndWhereTheAnswerGoes : IO Unit := do
  let page := consentPage (somePrompt) links.oauthAuthorize (some "csrf")
  checkEq "the name the client gave itself" true (mentions page "Some Agent")
  checkEq "the host that vouches for it" true (mentions page "agent.example")
  checkEq "and the anti-forgery token, without which the answer cannot be posted" true
    (mentions page "csrf")

/-- A client running on the person's own machine gets a warning of its own, because no document
can establish who is listening on a port of theirs. -/
private def testALoopbackClientIsCalledOut : IO Unit := do
  let ordinary := consentPage (somePrompt) links.oauthAuthorize none
  let loopback := consentPage (somePrompt (loopbackOnly := true)) links.oauthAuthorize none
  checkEq "the ordinary one says nothing about this device" false
    (mentions ordinary "on this device")
  checkEq "the loopback one does" true (mentions loopback "on this device")

/-- Each scope is its own field, so what comes back says which were left ticked rather than how
many were. A single repeated name would be read as one answer and the distinction between a
read-only grant and a full one would be lost. -/
private def testEachScopeIsItsOwnAnswer : IO Unit := do
  checkEq "the two scopes have two fields" false
    (approvalField Authorization.read == approvalField Authorization.write)
  let page := consentPage (somePrompt) links.oauthAuthorize none
  for scope in [Authorization.read, Authorization.write] do
    checkEq s!"{scope.value} has a box" true
      (mentions page (approvalField scope))

/-- A form field is matched by the bytes it comes back as, so its name has to be one a browser
returns unchanged.

`application/x-www-form-urlencoded` escapes everything outside this set, and a lookup that
encodes a character as itself never matches the escape a browser sent instead. What a scope is
called is the client's choice, so the test is over any scope a client could ask for rather than
over the two this server offers. -/
private def testAnApprovalFieldSurvivesBeingPostedByABrowser : IO Unit := do
  let unescaped (c : Char) : Bool :=
    c.isAlphanum || c == '*' || c == '-' || c == '.' || c == '_'
  let asked := Authorization.scopes ++ [⟨"a b"⟩, ⟨"%"⟩, ⟨"+"⟩, ⟨"emoji🙂"⟩]
  for scope in asked do
    checkEq s!"the field for {scope.value} needs no escaping" true
      ((approvalField scope).all unescaped)
  checkEq "and distinct scopes keep distinct fields" asked.length
    ((asked.map approvalField).eraseDups.length)

/-! ## The list on the page catching up -/

private def watch (digest : String) : String :=
  mkGetClose s!"{links.todosStatus}?seen={digest}"

/-- The digest has to move for every change the person can see, or the page silently stops
catching up. Each of these is a different field of the row, and a canonicalisation that dropped
one of them would leave that change invisible. -/
private def testTheDigestFollowsEveryVisibleChange : IO Unit := do
  let one : Item := { id := 1, title := "alpha", completed := false }
  let digest := listDigest #[one]
  checkEq "the same list digests the same" digest (listDigest #[one])
  checkEq "a retitle moves it" false (digest == listDigest #[{ one with title := "beta" }])
  checkEq "so does completing it" false (digest == listDigest #[{ one with completed := true }])
  checkEq "so does another todo" false (digest == listDigest #[one, { one with id := 2 }])
  checkEq "so does deleting it" false (digest == listDigest #[])

/-- A poll drawn against the list the store still holds is answered with nothing, so the page is
left alone. This is what makes the poll safe to run every few seconds: a swap would discard a
todo somebody is part-way through editing. -/
private def testAPollThatIsUpToDateChangesNothing : IO Unit := do
  let store ← memoryStore alice #[{ id := 1, title := "alpha", completed := false }]
  let handler ← siteOf store
  let current ← Async.block (runTelemetry (store.list alice .all))
  check "a poll holding the current digest" (watch (listDigest current)) handler
    fun response => do
      assertStatus response "HTTP/1.1 200"
      assertAbsent response "todo-list-section"

/-- The whole point: a change the browser did not make reaches the page it is not showing on.

The todo arrives through the MCP endpoint, which is as far from the browser as a change gets, and
the poll that follows carries the digest the page was drawn against before it. -/
private def testAChangeMadeElsewhereReachesThePage : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  let before ← Async.block (runTelemetry (store.list alice .all))
  check "an agent adds one" (call (callTool "add_todo" [("title", "gamma")])) handler
    fun response => assertStatus response "HTTP/1.1 200"
  check "the poll the page had already sent" (watch (listDigest before)) handler
    fun response => do
      assertContains response "gamma"
      -- Out of band, because the poll is answering an element that is not the list.
      assertContains response "hx-swap-oob"

def runMcpTests : IO Unit := do
  testAnAgentHoldingNothingCanFindTheWayIn
  testDiscoveryNeedsNoCredential
  testTheServerOffersNoWayInThatEndsInARefusal
  testAClientThatNamesNoScopesAsksForEverything
  testATokenIsRequired
  testAFullTokenReachesEveryTool
  testAReadOnlyTokenReachesOnlyTheReadingTools
  testAReadOnlyTokenCannotChangeAnything
  testCallsReachTheStoreAsTheTokensAccount
  testDuplicatedParametersSurviveBeingRead
  testTheConsentPageSaysWhoIsAskingAndWhereTheAnswerGoes
  testALoopbackClientIsCalledOut
  testEachScopeIsItsOwnAnswer
  testAnApprovalFieldSurvivesBeingPostedByABrowser
  testTheDigestFollowsEveryVisibleChange
  testAPollThatIsUpToDateChangesNothing
  testAChangeMadeElsewhereReachesThePage

end TodoTests
