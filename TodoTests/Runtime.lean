/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lambda
import TodoTests.Harness

namespace TodoTests

open Lambda
open Lean (Json)
open Std Async

/-- Reads one HTTP request off `client`: the head, then as much body as its `Content-Length`
announces. Stopping at the announced length rather than at end of file matters because the adapter
sends `Connection: close` but does not close its half before waiting for a reply. -/
private def readRequest (client : TCP.Socket.Client) : Async ByteArray := do
  let mut acc := ByteArray.empty
  let mut headEnd := none
  while headEnd.isNone do
    let some chunk ← client.recv? 4096 | return acc
    acc := acc ++ chunk
    headEnd := (List.range acc.size).find? fun i =>
      acc[i]? == some 13 && acc[i + 1]? == some 10
        && acc[i + 2]? == some 13 && acc[i + 3]? == some 10
  let some bodyStart := headEnd.map (· + 4) | return acc
  let head := (String.fromUTF8? (acc.extract 0 bodyStart)).getD ""
  let length :=
    (head.splitOn "\r\n" |>.findSome? fun line =>
      match line.splitOn ":" with
      | [name, value] =>
        if name.trimAscii.toString.toLower == "content-length" then value.trimAscii.toString.toNat?
        else none
      | _ => none).getD 0
  while acc.size < bodyStart + length do
    let some chunk ← client.recv? 4096 | return acc
    acc := acc ++ chunk
  pure acc

/-- Stands in for the execution environment's runtime API. Accepts one connection, reads the
request, then writes `reply` one element at a time.

`reply` is a list rather than a single blob so a test can choose where the response is split across
sends. That is the whole point of this harness: a reply that arrives in one piece exercises none of
the buffering, and the framing bug this file exists to guard against only appeared once a response
was large enough for the real runtime API to split it. -/
private def withRuntimeApi (reply : List ByteArray) (action : Endpoint → Async α) :
    IO (α × ByteArray) := do
  let server ← TCP.Socket.Server.mk
  server.bind (.v4 ⟨.ofParts 127 0 0 1, 0⟩)
  server.listen 1
  let port ←
    match ← server.getSockName with
    | .v4 addr => pure addr.port
    | .v6 addr => pure addr.port
  let some endpoint := Endpoint.ofString s!"127.0.0.1:{port}"
    | throw (IO.userError "could not build an endpoint for the fake runtime API")
  let served ← IO.asTask <| Async.block do
    let client ← server.accept
    let request ← readRequest client
    -- Best-effort: an adapter that gives up part way through leaves these sends writing to a
    -- socket nobody is reading, and that failure would otherwise surface instead of the one the
    -- test is actually about.
    try
      for chunk in reply do
        client.send chunk
      client.shutdown
    catch _ => pure ()
    pure request
  let result ← Async.block (action endpoint)
  match ← IO.wait served with
  | .ok request => pure (result, request)
  | .error e => throw e

private def bytes (s : String) : ByteArray := s.toUTF8

/-- A minimal but realistic payload format 2.0 event. -/
private def event : String :=
  "{\"version\":\"2.0\",\"rawPath\":\"/\",\"rawQueryString\":\"\",\"headers\":{}," ++
  "\"requestContext\":{\"http\":{\"method\":\"GET\",\"sourceIp\":\"203.0.113.7\"}}," ++
  "\"body\":\"\",\"isBase64Encoded\":false}"

private def requestId : String := "8476a536-e9f4-11e8-9739-2dfe598c3fcd"

private def withLength (body : String) : String :=
  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
  s!"Lambda-Runtime-Aws-Request-Id: {requestId}\r\n" ++
  s!"Content-Length: {body.toUTF8.size}\r\n\r\n" ++ body

/-- The same response framed the way the real runtime API frames a larger one. -/
private def asChunked (body : String) (splitAt : Nat) : String :=
  let head := body.toUTF8.extract 0 (min splitAt body.toUTF8.size)
  let tail := body.toUTF8.extract (min splitAt body.toUTF8.size) body.toUTF8.size
  let hex (n : Nat) : String := String.ofList (Nat.toDigits 16 n)
  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
  s!"Lambda-Runtime-Aws-Request-Id: {requestId}\r\n" ++
  "Transfer-Encoding: chunked\r\n\r\n" ++
  s!"{hex head.size}\r\n{(String.fromUTF8? head).getD ""}\r\n" ++
  s!"{hex tail.size}\r\n{(String.fromUTF8? tail).getD ""}\r\n" ++
  "0\r\n\r\n"

private def fetchNext (reply : List ByteArray) : IO (Except String Invocation × ByteArray) :=
  withRuntimeApi reply fun endpoint => (next endpoint).run

private def expectInvocation (label : String) (reply : List ByteArray) : IO Unit := do
  let (result, request) ← fetchNext reply
  match result with
  | .error e => throw (IO.userError s!"{label}: expected an invocation, got error {e}")
  | .ok invocation =>
    checkEq s!"{label}: request id" requestId invocation.requestId
    checkEq s!"{label}: event" (Json.parse event |>.toOption.map Json.compress)
      (some invocation.event.compress)
    let text := (String.fromUTF8? request).getD ""
    unless text.startsWith "GET /2018-06-01/runtime/invocation/next HTTP/1.1\r\n" do
      throw (IO.userError s!"{label}: unexpected request line in {text}")

/-- Content-length framing, which is all the emulator used locally, so it is the case that always
worked. -/
private def testNextWithContentLength : IO Unit :=
  expectInvocation "content-length" [bytes (withLength event)]

/-- Chunked framing, which the deployed runtime API uses once a response is large enough. Rejecting
it reached production as a 502 on every browser mutation, since a browser's request carries enough
headers to cross whatever threshold triggers it. -/
private def testNextWithChunkedEncoding : IO Unit :=
  expectInvocation "chunked" [bytes (asChunked event 40)]

/-- The framing bug's real shape: a chunked body that cannot arrive in one read, so decoding has to
resume rather than conclude the response is malformed.

Made to span reads by size rather than by writing it in pieces. Writing in pieces does not settle
anything, because loopback coalesces sends often enough that the decoder still sees the whole body
at once and the resume path goes unexercised while the test passes; exceeding the adapter's own read
buffer forces more than one read whatever the network does. -/
private def testNextWithChunkedSpanningReads : IO Unit := do
  let padded :=
    "{\"version\":\"2.0\",\"rawPath\":\"/\",\"rawQueryString\":\"\",\"headers\":{}," ++
    "\"requestContext\":{\"http\":{\"method\":\"GET\",\"sourceIp\":\"203.0.113.7\"}}," ++
    s!"\"padding\":\"{String.ofList (List.replicate 100000 'a')}\"," ++
    "\"body\":\"\",\"isBase64Encoded\":false}"
  let (result, _) ← fetchNext [bytes (asChunked padded 40)]
  match result with
  | .error e => throw (IO.userError s!"chunked spanning reads: expected an invocation, got {e}")
  | .ok invocation =>
    checkEq "chunked spanning reads: request id" requestId invocation.requestId
    -- Asserted by length and content rather than by comparing the string, so that a truncated body
    -- reports the size it stopped at instead of printing a hundred thousand characters twice.
    let padding := (invocation.event.getObjVal? "padding" >>= Json.getStr?).toOption
    checkEq "chunked spanning reads: padding length" (some 100000) (padding.map (·.length))
    checkEq "chunked spanning reads: padding intact" (some true)
      (padding.map (·.all (· == 'a')))

/-- A chunked response arriving in more than one send, which is the shape the deployed runtime API
delivered the payload that first exposed the framing bug in.

Which of these split points the decoder actually sees as a partial read is up to the network, so
this covers the arrival shape and not the resume path; `testNextWithChunkedSpanningReads` is what
pins the latter down. -/
private def testNextWithChunkedSplitAcrossSends : IO Unit := do
  let raw := (asChunked event 40).toUTF8
  for splitAt in [1, 20, 60, 100, 140, 180, raw.size - 3] do
    let cut := min splitAt raw.size
    expectInvocation s!"chunked split at {cut}"
      [raw.extract 0 cut, raw.extract cut raw.size]

/-- A response head split across sends, which the adapter has to accumulate before it can find the
end of the headers. -/
private def testNextWithSplitHead : IO Unit := do
  let raw := (withLength event).toUTF8
  expectInvocation "head split mid-header" [raw.extract 0 30, raw.extract 30 raw.size]

/-- Without a request id there is nothing to report an outcome against, so this has to fail rather
than proceed with an invocation it cannot answer. -/
private def testNextRejectsMissingRequestId : IO Unit := do
  let reply := "HTTP/1.1 200 OK\r\n" ++ s!"Content-Length: {event.toUTF8.size}\r\n\r\n" ++ event
  let (result, _) ← fetchNext [bytes reply]
  if let .ok _ := result then
    throw (IO.userError "expected a response with no request id to be rejected")

private def testNextRejectsMalformedJson : IO Unit := do
  let (result, _) ← fetchNext [bytes (withLength "{\"version\": ")]
  if let .ok _ := result then
    throw (IO.userError "expected a malformed event to be rejected")

/-- What the adapter puts on the wire when it answers, checked against the runtime API contract:
the id has to appear in the path, since that is the only thing tying a response to its invocation,
and the payload has to be the response document rather than anything wrapping it. -/
private def testPostResponseSendsThePayload : IO Unit := do
  let payload := Json.mkObj [("statusCode", Json.num 200), ("body", Json.str "hi")]
  let (_, request) ← withRuntimeApi [bytes "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n"]
    fun endpoint => (postResponse endpoint requestId payload).run
  let text := (String.fromUTF8? request).getD ""
  unless text.startsWith s!"POST /2018-06-01/runtime/invocation/{requestId}/response HTTP/1.1\r\n" do
    throw (IO.userError s!"unexpected request line in {text}")
  unless (text.splitOn "\r\n\r\n")[1]? == some payload.compress do
    throw (IO.userError s!"unexpected body in {text}")

/-- An adapter-level failure has to reach `/error`, because an invocation left unanswered stays
open until Lambda times it out. -/
private def testPostErrorReportsAgainstTheInvocation : IO Unit := do
  let (_, request) ← withRuntimeApi [bytes "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n"]
    fun endpoint => (postError endpoint requestId "something went wrong").run
  let text := (String.fromUTF8? request).getD ""
  unless text.startsWith s!"POST /2018-06-01/runtime/invocation/{requestId}/error HTTP/1.1\r\n" do
    throw (IO.userError s!"unexpected request line in {text}")
  unless (text.splitOn "something went wrong").length == 2 do
    throw (IO.userError s!"error message did not reach the payload: {text}")

def runRuntimeTests : IO Unit := do
  testNextWithContentLength
  testNextWithChunkedEncoding
  testNextWithChunkedSpanningReads
  testNextWithChunkedSplitAcrossSends
  testNextWithSplitHead
  testNextRejectsMissingRequestId
  testNextRejectsMalformedJson
  testPostResponseSendsThePayload
  testPostErrorReportsAgainstTheInvocation

end TodoTests
