/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lambda.Event
import Lean.Data.Json
import Std.Http.Server
import Std.Net.Addr

open Lean (Json)
open Std Async
open Std Http
open Std Http Server

namespace Lambda

private def readChunkSize : UInt64 := 65536

private def maxHeadBytes : Nat := 32768

/-- The runtime API's own responses, as distinct from the responses this adapter produces for
the caller of the function URL. -/
private structure ApiResponse where
  status : Nat
  headers : Array (String × String)
  body : ByteArray

private abbrev Api := ExceptT String Async

/-- Where the runtime API listens, in the `host:port` form the execution environment advertises
it as. `host` is kept as written so it can go straight back out as the `Host` header. -/
structure Endpoint where
  host : String
  addr : Std.Net.SocketAddress

/-- The execution environment advertises a literal address rather than a name, so this parses a
dotted quad instead of resolving through DNS. -/
def Endpoint.ofString (s : String) : Option Endpoint := do
  let (host, port) ←
    match s.splitOn ":" with
    | [host, port] => do
      let port ← port.toNat?
      if port < 65536 then some (host, port.toUInt16) else none
    | _ => none
  let octets ← (host.splitOn ".").mapM fun part => do
    let n ← part.toNat?
    if n < 256 then some n.toUInt8 else none
  match octets with
  | [a, b, c, d] => some { host := s, addr := .v4 ⟨.ofParts a b c d, port⟩ }
  | _ => none

private def isHeadEnd (bytes : ByteArray) (i : Nat) : Bool :=
  bytes[i]? == some 13 && bytes[i + 1]? == some 10
    && bytes[i + 2]? == some 13 && bytes[i + 3]? == some 10

private def headEnd (bytes : ByteArray) : Option Nat :=
  (List.range bytes.size).find? (isHeadEnd bytes)

private def readHead (socket : TCP.Socket.Client) : Api (ByteArray × Nat) := do
  let mut acc := ByteArray.empty
  let mut closed := false
  while (headEnd acc).isNone do
    if closed then
      throw "the runtime API closed the connection before completing the response head"
    if acc.size > maxHeadBytes then
      throw "the runtime API response head exceeds the read limit"
    match ← socket.recv? readChunkSize with
    | none => closed := true
    | some chunk => acc := acc ++ chunk
  match headEnd acc with
  | some i => pure (acc, i + 4)
  | none => throw "the runtime API response head is incomplete"

/-- With no `Content-Length` the message runs to the end of the connection, which the
`Connection: close` on every request makes a usable boundary. -/
private def readToEnd (socket : TCP.Socket.Client) (buffered : ByteArray) : Api ByteArray := do
  let mut acc := buffered
  let mut reading := true
  while reading do
    match ← socket.recv? readChunkSize with
    | none => reading := false
    | some chunk => acc := acc ++ chunk
  pure acc

private def readBody (socket : TCP.Socket.Client) (buffered : ByteArray) (length : Option Nat) :
    Api ByteArray := do
  let some length := length | readToEnd socket buffered
  let mut acc := buffered
  let mut closed := false
  while acc.size < length do
    if closed then
      throw "the runtime API closed the connection before completing the response body"
    match ← socket.recv? readChunkSize with
    | none => closed := true
    | some chunk => acc := acc ++ chunk
  pure (acc.extract 0 length)

private def parseHead (text : String) : Except String (Nat × Array (String × String)) := do
  match text.splitOn "\r\n" with
  | [] => throw "empty runtime API response head"
  | statusLine :: rest =>
    let some status := (statusLine.splitOn " ")[1]?.bind (·.toNat?)
      | throw s!"malformed runtime API status line: {statusLine}"
    let headers := rest.filterMap fun line =>
      match line.splitOn ":" with
      | name :: value :: more =>
        some (name.trimAscii.toString.toLower,
          (String.intercalate ":" (value :: more)).trimAscii.toString)
      | _ => none
    pure (status, headers.toArray)

/-- One request per connection. The `/next` call blocks until an invocation arrives and the
environment is frozen in between, so a connection held across invocations would be resumed
against a peer that may long since have dropped it. -/
private def request (endpoint : Endpoint) (method path : String) (body : Option ByteArray) :
    Api ApiResponse := do
  let socket ← TCP.Socket.Client.mk
  socket.connect endpoint.addr
  let head :=
    s!"{method} {path} HTTP/1.1\r\nHost: {endpoint.host}\r\nConnection: close\r\n"
      ++ (match body with
          | some body => s!"Content-Type: application/json\r\nContent-Length: {body.size}\r\n"
          | none => "")
      ++ "\r\n"
  socket.send (head.toUTF8 ++ body.getD .empty)
  let (buffered, bodyStart) ← readHead socket
  let some text := String.fromUTF8? (buffered.extract 0 (bodyStart - 4))
    | throw "the runtime API response head is not valid UTF-8"
  let (status, headers) ← parseHead text
  let header (name : String) := (headers.find? (·.1 == name)).map (·.2)
  if let some encoding := header "transfer-encoding" then
    throw s!"the runtime API used an unsupported transfer-encoding: {encoding}"
  let body ← readBody socket (buffered.extract bodyStart buffered.size)
    ((header "content-length").bind (·.toNat?))
  pure { status, headers, body }

/-- An invocation, paired with the id every subsequent call about it has to quote. -/
structure Invocation where
  requestId : String
  event : Json

def next (endpoint : Endpoint) : Api Invocation := do
  let response ← request endpoint "GET" "/2018-06-01/runtime/invocation/next" none
  let some requestId := (response.headers.find? (·.1 == "lambda-runtime-aws-request-id")).map (·.2)
    | throw "the runtime API did not identify the invocation"
  let some text := String.fromUTF8? response.body
    | throw "the invocation event is not valid UTF-8"
  match Json.parse text with
  | .ok event => pure { requestId, event }
  | .error e => throw s!"the invocation event is not valid JSON: {e}"

def postResponse (endpoint : Endpoint) (requestId : String) (payload : Json) : Api Unit := do
  discard <| request endpoint "POST" s!"/2018-06-01/runtime/invocation/{requestId}/response"
    (some payload.compress.toUTF8)

private def errorPayload (message : String) : ByteArray :=
  (Json.mkObj [("errorMessage", Json.str message), ("errorType", Json.str "AdapterError")]).compress.toUTF8

def postError (endpoint : Endpoint) (requestId message : String) : Api Unit := do
  discard <| request endpoint "POST" s!"/2018-06-01/runtime/invocation/{requestId}/error"
    (some (errorPayload message))

def postInitError (endpoint : Endpoint) (message : String) : Api Unit := do
  discard <| request endpoint "POST" "/2018-06-01/runtime/init/error" (some (errorPayload message))

private def invoke (handler : StatelessHandler) (event : Json) : Api Json := do
  let event ← ExceptT.mk (pure (Event.ofJson event))
  let request ← ExceptT.mk (Event.toRequest event)
  let response ← (handler.onRequest request).run
  ExceptT.mk (responseToJson response)

/-- Serves invocations until the execution environment is torn down.

A failure inside the handler has already been turned into a 500 by the `catchAll` middleware, so
reaching the `/error` endpoint means the adapter itself could not produce a response. Reporting it
matters because the alternative is an invocation that stays open until Lambda times it out. -/
def run (handler : StatelessHandler) (endpoint : Endpoint) : Async Unit := do
  while true do
    match ← (next endpoint).run with
    | .error e =>
      -- With no request id there is no invocation endpoint to report this against.
      IO.eprintln s!"lambda: could not fetch the next invocation: {e}"
    | .ok invocation =>
      let outcome ←
        try (invoke handler invocation.event).run
        catch e => pure (.error (toString e))
      let posted ←
        match outcome with
        | .ok payload => (postResponse endpoint invocation.requestId payload).run
        | .error e => (postError endpoint invocation.requestId e).run
      if let .error e := posted then
        IO.eprintln s!"lambda: could not report the outcome of {invocation.requestId}: {e}"

end Lambda
