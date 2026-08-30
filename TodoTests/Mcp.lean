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

/-! ## What a token reaches

The tests below drive the endpoint with tokens and read what comes back, which establishes these
claims for the tools that exist today. These state them for every token and every tool, including
the ones nobody has written yet: a tool added to the registry is covered the moment it compiles,
which is what a table of cases cannot promise. -/

/-- An agent is offered a tool exactly when this application implements it and the agent's token
holds the scope it needs. Soundness alone would be satisfied by a server that offered nothing at
all, so the other half is what makes the first mean anything.

`Mcp.permitted held` is the catalogue the endpoint answers a token holding `held` with, so the
left of the `↔` says `entry` is among the tools that token is offered. On the right,
`entry ∈ ChatTools.registry` says the entry is one the application actually implements, and
`Mcp.scopeFor entry ∈ held` says the token holds the single scope that entry requires. Reading it
in both directions: nothing outside the registry can be conjured into a catalogue, no tool whose
scope is absent can appear in one, and no tool meeting both conditions is withheld. -/
theorem permitted_iff (held : List Authentication.OAuth.Scope) (entry : ChatTools.Entry) :
    entry ∈ Mcp.permitted held ↔ entry ∈ ChatTools.registry ∧ Mcp.scopeFor entry ∈ held := by
  simp [Mcp.permitted, Array.mem_filter]

/-- A grant that withheld `todos:write` reaches nothing that changes anything. This is what the
consent page's second checkbox is for, and it holds however many tools are added and whatever
they are called.

`held` is the scope list carried by a token; `withheld` says `Authorization.write`, the
`todos:write` scope, is not in it; `offered` says `entry` is one of the tools that token is
handed. The conclusion is the registry's own flag for a tool that changes the list, so what is
ruled out is not that such a tool fails when called but that it is ever put in front of the agent
at all. The hypotheses are satisfiable rather than contradictory: a token holding only
`Authorization.read` withholds `write` and is still offered every read-only tool, so this is not
vacuously true. -/
theorem nothing_mutates_without_write (held : List Authentication.OAuth.Scope)
    (entry : ChatTools.Entry) (withheld : Authorization.write ∉ held)
    (offered : entry ∈ Mcp.permitted held) : entry.mutates = false := by
  have holds := ((permitted_iff held entry).mp offered).2
  by_cases mutates : entry.mutates
  · simp [Mcp.scopeFor, mutates] at holds
    exact absurd holds withheld
  · simpa using mutates

/-- A token holding no scopes reaches no tool, which is what `mcpHandler` refuses on rather than
serving an empty catalogue. An agent handed an empty catalogue has no way to tell a grant that is
useless from a server that has nothing to offer, and will go on refreshing it.

`Mcp.permitted []` is the catalogue computed for a token holding no scopes at all, and `#[]` is
the empty array, so no entry survives the filter whatever the registry comes to hold. It is the
case of `permitted_iff` in which the right-hand conjunct cannot be met, stated on its own because
the handler branches on precisely this array being empty. -/
theorem permitted_none : Mcp.permitted [] = #[] := by simp [Mcp.permitted]

private def readOnly : String := "read-only-token"
private def fullAccess : String := "full-access-token"

private def scopeless : String := "scopeless-token"

private def issued : List (String × Account × List Authorization.Scope) :=
  [ (readOnly, alice, [Authorization.read]),
    (fullAccess, alice, [Authorization.read, Authorization.write]),
    (scopeless, alice, []) ]

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
    site (← oauthRoutesOn)).onRequest

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

/-- A token that reaches no tool is refused, rather than served an empty list of them.

An empty list is what a client shows for a server with nothing on it, so a grant made before the
client knew what to ask for looks like success and stays broken. The challenge names the scopes
instead, which is the only thing that tells a client to come back and ask again. -/
private def testATokenThatReachesNothingIsRefusedRatherThanServedNothing : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "a token carrying no scopes" (call listTools (some s!"Bearer {scopeless}")) handler
    fun response => do
      assertStatus response "HTTP/1.1 403"
      assertContains response "insufficient_scope"
      for scope in Authorization.scopes do
        assertContains response scope.value

/-- A refusal says why in its body as well as its header.

A Lambda function URL renames `WWW-Authenticate` on the way out and nothing configures that away,
so a deployment can refuse correctly and still tell the client nothing. The body is the half that
arrives. Read here rather than off the response, because both carry the same strings and a check
on the response could not tell which of them it had found.

The header is the library's and the document is this application's, so the last assertion is what
catches them drifting apart about what a refusal is called. -/
private def testARefusalSaysWhyInItsBodyToo : IO Unit := do
  let cases : List (Authorization.Rejection × String × Nat) :=
    [ (.unknown, "invalid_token", 401),
      (.insufficientScope Authorization.scopes, "insufficient_scope", 403) ]
  for (rejection, code, status) in cases do
    let refused := Authorization.challengeFor testBase rejection
    let document := Json.compress refused.document
    checkEq s!"{code} carries the status RFC 6750 gives it" status refused.status
    checkEq s!"the document names {code}" true (mentions document code)
    checkEq "and where to go for a token" true
      (mentions document (Authorization.metadataUrl testBase))
    checkEq s!"and the header agrees it is {code}" true (mentions refused.header code)
  -- Naming them is the whole point of the scope case: a client refused without being told what to
  -- ask for has nothing to come back with.
  let narrowed := Authorization.challengeFor testBase (.insufficientScope Authorization.scopes)
  for scope in Authorization.scopes do
    checkEq s!"the document names {scope.value}" true
      (mentions (Json.compress narrowed.document) scope.value)

/-- RFC 9728 puts the resource's path into the well-known URL, and that is the form a client
tries first: a 404 there costs it the document unless it also tries the shorter one. -/
private def testTheResourceDocumentIsWhereAClientLooksFirst : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  for path in [links.mcpMetadata, links.mcpMetadataForEndpoint] do
    check s!"GET {path}" (mkGetClose path) handler fun response => do
      assertStatus response "HTTP/1.1 200"
      assertContains response (Authorization.resource testBase).value

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

/-! ## Asking the person -/

/-- What the consent page is handed, which the library builds from the prompt and the request it
arrived on. Written out here because the page is this application's and reading it is the only
way to check that what a person is shown is what the specification requires. -/
private def someContext (loopbackOnly : Bool := false) :
    Authentication.OAuth.Http.ConsentContext :=
  { tenantName := "TodoMVC"
    action := links.oauthAuthorize
    antiForgeryField := ({} : Middleware.AntiForgeryOptions).paramName
    antiForgeryToken := "csrf"
    clientName := "Some Agent"
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
  let page := consentPage (someContext)
  checkEq "the name the client gave itself" true (mentions page "Some Agent")
  checkEq "the host that vouches for it" true (mentions page "agent.example")
  checkEq "and the anti-forgery token, without which the answer cannot be posted" true
    (mentions page "csrf")

/-- A client running on the person's own machine gets a warning of its own, because no document
can establish who is listening on a port of theirs. -/
private def testALoopbackClientIsCalledOut : IO Unit := do
  let ordinary := consentPage (someContext)
  let loopback := consentPage (someContext (loopbackOnly := true))
  checkEq "the ordinary one says nothing about this device" false
    (mentions ordinary "on this device")
  checkEq "the loopback one does" true (mentions loopback "on this device")

/-- The page puts every scope on offer behind the field name the handler reads it back under.
One name per scope is what makes the answer say which were left ticked rather than how many. -/
private def testEachScopeIsItsOwnAnswer : IO Unit := do
  let page := consentPage (someContext)
  for scope in [Authorization.read, Authorization.write] do
    checkEq s!"{scope.value} has a box" true
      (mentions page scope.approvalField)


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
  testTheResourceDocumentIsWhereAClientLooksFirst
  testATokenThatReachesNothingIsRefusedRatherThanServedNothing
  testARefusalSaysWhyInItsBodyToo
  testTheServerOffersNoWayInThatEndsInARefusal
  testATokenIsRequired
  testAFullTokenReachesEveryTool
  testAReadOnlyTokenReachesOnlyTheReadingTools
  testAReadOnlyTokenCannotChangeAnything
  testCallsReachTheStoreAsTheTokensAccount
  testTheConsentPageSaysWhoIsAskingAndWhereTheAnswerGoes
  testALoopbackClientIsCalledOut
  testEachScopeIsItsOwnAnswer
  testTheDigestFollowsEveryVisibleChange
  testAPollThatIsUpToDateChangesNothing
  testAChangeMadeElsewhereReachesThePage

end TodoTests
