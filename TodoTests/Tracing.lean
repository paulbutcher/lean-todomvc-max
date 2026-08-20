/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Telemetry.Testing
public import Todo.App
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Std.Async (Async)
open Std.Http.Internal.Test
open Telemetry
open Telemetry.Sdk (SpanData)
open Telemetry.Testing

private def active : Item := { id := 1, title := "alpha", completed := false }

/-- The full stack rather than `Todo.app`, since `serverSpan` is part of the stack and not of the
route table. -/
private def serverOf (store : Store) : IO TestHandler := do
  let sessions ← Middleware.MemoryStore.new
  pure (Todo.server store sessions).onRequest

private def spansFor (handler : TestHandler) (raw : String)
    (expect : ByteArray → IO Unit := fun _ => pure ()) : IO (Array SpanData) := do
  let (_, captured) ← capture (check "request" raw handler expect)
  return captured.spans

private def theServerSpan (spans : Array SpanData) : IO SpanData := do
  let some span := spans.find? (·.kind == .server)
    | throw (IO.userError "no server span was emitted")
  return span

/-- Two requests to one endpoint differing only in the id have to arrive under a single name.
Otherwise every id is an endpoint of its own and grouping by name says nothing at all. -/
private def testServerSpanNamesTheEndpointNotTheRequest : IO Unit := do
  let handler ← serverOf (← memoryStore #[active])
  let first ← theServerSpan (← spansFor handler (mkGetClose "/todos/1/edit"))
  let second ← theServerSpan (← spansFor handler (mkGetClose "/todos/2/edit"))
  checkEq "the two requests were of different paths" false
    (first.attrs.lookup Conventions.urlPath == second.attrs.lookup Conventions.urlPath)
  checkEq "yet share one span name" first.name second.name
  checkEq "which is the route the router matched" true
    (first.attrs.lookup Conventions.httpRoute).isSome

/-- Nothing matched, so there is no endpoint to name and a guess would be worse than silence. -/
private def testUnmatchedRequestCarriesNoRoute : IO Unit := do
  let handler ← serverOf (← memoryStore #[])
  let span ← theServerSpan (← spansFor handler (mkGetClose "/nothing-here"))
  checkEq "no route was invented" none (span.attrs.lookup Conventions.httpRoute)

/-- Records the span each operation was invoked under, which is the only thing about it that
matters here. -/
private def spyStore (seen : IO.Ref (Array (Option SpanContext))) : Store where
  list _ := do seen.modify (·.push (← currentSpan)); pure #[]
  add _ := do seen.modify (·.push (← currentSpan))
  toggle _ := do seen.modify (·.push (← currentSpan))
  delete _ := do seen.modify (·.push (← currentSpan))
  setTitle _ _ := do seen.modify (·.push (← currentSpan))
  toggleAll := do seen.modify (·.push (← currentSpan))
  clearCompleted := do seen.modify (·.push (← currentSpan))

/-- A store operation runs under the request's own span. That is what makes the spans it opens
children of the request rather than roots, and it is the fragile half of the arrangement: the
`SpanContext` has to survive the trip out through the request's extensions and back into a
`TelemetryT` at the handler. What the store then does with it is `Telemetry.span`'s business. -/
private def testStoreOperationsRunUnderTheRequestSpan : IO Unit := do
  let seen ← IO.mkRef #[]
  let handler ← serverOf (spyStore seen)
  let server ← theServerSpan (← spansFor handler (mkGetClose "/"))
  let seen ← seen.get
  checkEq "the page reached the store at all" false seen.isEmpty
  checkEq "under the request's span, every time" #[] (seen.filter (· != some server.ctx))

private def failWith (message : String) : TelemetryT Async α :=
  liftM (show IO α from throw (IO.userError message))

/-- Every operation fails, as they all would with the database unreachable. -/
private def failingStore (message : String) : Store where
  list _ := failWith message
  add _ := failWith message
  toggle _ := failWith message
  delete _ := failWith message
  setTitle _ _ := failWith message
  toggleAll := failWith message
  clearCompleted := failWith message

/-- `serverSpan` sits inside `catchAll` precisely so that a failure reaches it as the exception it
was, rather than as the `500` that carries no trace of why. Losing the cause here would be the
whole placement wasted, and the response is still the clean `500` a client should see. -/
private def testAFailedRequestIsReportedWithItsCause : IO Unit := do
  let handler ← serverOf (failingStore "database is unreachable")
  let spans ← spansFor handler (mkGetClose "/") fun response =>
    assertStatus response "HTTP/1.1 500"
  let span ← theServerSpan spans
  checkEq "the span failed" StatusCode.error span.status
  checkEq "carrying the cause" (some "database is unreachable") span.statusMessage

def runTracingTests : IO Unit := do
  testServerSpanNamesTheEndpointNotTheRequest
  testUnmatchedRequestCarriesNoRoute
  testStoreOperationsRunUnderTheRequestSpan
  testAFailedRequestIsReportedWithItsCause

end TodoTests
