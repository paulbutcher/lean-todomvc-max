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

/-! ## The endpoint an outside agent reaches

What the protocol does with a request is `lean-mcp`'s to answer for, and it does. What is checked
here is the wiring: that the credential is required, that the tools reached are the registry's
own, that they run as the account the settings name, and that none of the middleware standing in
front of the browser routes stands in front of this one. -/

private def token : String := "s3cret"

private def settings : Mcp.Settings := { token, account := alice }

/-- The whole stack, not just the handler: the point of several of these is that a request
carrying no session and no anti-forgery token gets through it, which only the real middleware can
demonstrate. -/
private def siteOf (store : Store) (mcpSettings : Option Mcp.Settings := some settings) :
    IO TestHandler := do
  let assistant ← scriptedAssistant #[]
  let sessions ← Middleware.MemoryStore.new
  let auth : StatelessHandler :=
    { onRequest := fun _ => "no sign-in here" |> Response.notFound.text }
  pure (Todo.server (fixedIdentity alice (← IO.mkRef 0)) auth store assistant sessions
    (mcpSettings := mcpSettings)).onRequest

private def call (body : String) (credential : Option String := some s!"Bearer {token}") :
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

/-! ## What the deployment configured -/

private def resolving : String → IO (Option Account) := fun raw =>
  pure (if raw == "alice@example.com" then some alice else none)

private def described : Mcp.Configuration → String
  | .off => "off"
  | .on settings => s!"on as {settings.account.value}"
  | .misconfigured _ => "misconfigured"

/-- The account is named by the address it signs in with, because that is what somebody setting
this has to hand. An address belonging to nobody is a mistake and says so: the endpoint it would
otherwise produce answers every question with an empty list, which looks like an empty list
rather than like a misconfiguration. -/
private def testTheAccountIsNamedByItsAddress : IO Unit := do
  let settingsFor := Mcp.settingsFor resolving
  checkEq "an address that signs in resolves to its account" "on as alice"
    (described (← settingsFor (some token) (some "alice@example.com")))
  checkEq "one that belongs to nobody is a mistake, not an empty list" "misconfigured"
    (described (← settingsFor (some token) (some "nobody@example.com")))
  checkEq "and so is an account id, which is not an address" "misconfigured"
    (described (← settingsFor (some token) (some alice.value)))
  checkEq "half the settings is a mistake too" "misconfigured"
    (described (← settingsFor (some token) none))
  checkEq "neither is simply off" "off" (described (← settingsFor none none))

/-! ## The endpoint -/

/-- Without the credential nothing runs, and the refusal names the scheme so a client knows what
would have been accepted. A wrong credential is refused the same way as none at all. -/
private def testTheCredentialIsRequired : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "no Authorization header" (call (callTool "add_todo" [("title", "gamma")]) none) handler
    fun response => do
      assertStatus response "HTTP/1.1 401"
      -- The scheme, not the header name, which the server is free to re-case.
      assertContains response "Bearer"
  check "the wrong token" (call (callTool "add_todo" [("title", "delta")]) (some "Bearer wrong"))
    handler fun response => assertStatus response "HTTP/1.1 401"
  checkEq "and neither of them reached the store" #[] (← titlesOf store)

/-- A deployment that configured no credential has no endpoint, rather than one that refuses
everything: the second would advertise a feature that is not on offer. -/
private def testItIsAbsentUntilConfigured : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store (mcpSettings := none)
  check "with no settings" (call listTools) handler fun response =>
    assertStatus response "HTTP/1.1 404"

/-- Every tool the panel's model is offered is offered here too, because both come from the one
registry. Stated over the registry rather than a list written out again, so a tool added to it is
covered without this test being touched. -/
private def testTheToolsAreTheRegistrys : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "tools/list" (call listTools) handler fun response => do
    assertStatus response "HTTP/1.1 200"
    for entry in ChatTools.registry do
      assertContains response entry.tool.name

/-- The call reaches the store, as the account the settings name and no other.

This is also what shows the endpoint standing outside the middleware the browser routes sit
behind: the request carries no session cookie and no anti-forgery token, and `antiForgery` would
refuse a POST that carried neither. -/
private def testCallsReachTheStoreAsTheConfiguredAccount : IO Unit := do
  let store ← memoryStore alice #[]
  let handler ← siteOf store
  check "tools/call add_todo" (call (callTool "add_todo" [("title", "gamma")])) handler
    fun response => assertStatus response "HTTP/1.1 200"
  checkEq "the todo is alice's" #["gamma"] (← titlesOf store)
  checkEq "and nobody else's" #[] (← titlesOf store bob)

def runMcpTests : IO Unit := do
  testTheAccountIsNamedByItsAddress
  testTheCredentialIsRequired
  testItIsAbsentUntilConfigured
  testTheToolsAreTheRegistrys
  testCallsReachTheStoreAsTheConfiguredAccount

end TodoTests
