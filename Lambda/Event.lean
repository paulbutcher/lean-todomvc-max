/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean.Data.Json
import Middleware
import Std.Http.Server

open Lean (Json)
open Std Async
open Std Http
open Std Http Server

namespace Lambda

/-- Lambda rejects a buffered response payload larger than this, so a response that exceeds it
can't be delivered however we handle it here. -/
def maxResponseBytes : Nat := 6 * 1024 * 1024

/-- The fields of an API Gateway payload format 2.0 event that this adapter uses. Everything
else the event carries (authorizer identity, stage variables, timestamps) has no bearing on the
`Request` the handler sees. -/
structure Event where
  method : String
  rawPath : String
  rawQueryString : String
  headers : Array (String × String)
  cookies : Array String
  sourceIp : String
  body : ByteArray
deriving Inhabited

namespace Event

private def stringFields (j : Json) : Array (String × String) :=
  match j with
  | .obj kvs => kvs.foldl (init := #[]) fun acc k v =>
    match v with
    | .str s => acc.push (k, s)
    | _ => acc
  | _ => #[]

private def strings (j : Json) : Array String :=
  match j with
  | .arr elems => elems.filterMap fun
    | .str s => some s
    | _ => none
  | _ => #[]

private def orDefault (e : Except String α) (fallback : α) : α :=
  match e with
  | .ok v => v
  | .error _ => fallback

def ofJson (j : Json) : Except String Event := do
  let http ← j.getObjVal? "requestContext" >>= (Json.getObjVal? · "http")
  let method ← http.getObjVal? "method" >>= Json.getStr?
  let sourceIp ← http.getObjVal? "sourceIp" >>= Json.getStr?
  let rawPath ← j.getObjVal? "rawPath" >>= Json.getStr?
  let rawQueryString := orDefault (j.getObjVal? "rawQueryString" >>= Json.getStr?) ""
  let headers := stringFields (orDefault (j.getObjVal? "headers") .null)
  let cookies := strings (orDefault (j.getObjVal? "cookies") .null)
  let raw := orDefault (j.getObjVal? "body" >>= Json.getStr?) ""
  let body ←
    if orDefault (j.getObjVal? "isBase64Encoded" >>= Json.getBool?) false then
      match Middleware.Crypto.Base64.decode raw with
      | some bytes => pure bytes
      | none => throw "isBase64Encoded is set but the body is not valid base64"
    else
      pure raw.toUTF8
  pure { method, rawPath, rawQueryString, headers, cookies, sourceIp, body }

/-- Names `requestHeaders` sets itself, and therefore ignores in the event's header map. -/
def isAdapterOwned (name : String) : Bool :=
  let name := name.toLower
  name == "cookie" || name == "x-forwarded-for" || name == "x-forwarded-proto"

/-- The headers the handler sees. Three of them come from the adapter rather than from the
event's own header map, and each is a correctness requirement rather than a tidying-up:

* `Cookie` is reassembled from the event's `cookies` array. Payload format 2.0 delivers request
  cookies there and omits the header entirely, so without this the request reaching the handler
  has no cookies at all and every session lookup and anti-forgery check fails.
* `X-Forwarded-For` is set from `requestContext.http.sourceIp`, discarding whatever the client
  sent. A function URL truncates `x-forwarded-for` to its leftmost entry, which is the entry the
  client controls, so forwarding the header on would hand `forwardedRemoteAddr` an address the
  caller chose for itself.
* `X-Forwarded-Proto` is always `https`. A function URL has no plaintext listener, and
  `requestOrigin` assumes `http` when nothing tells it otherwise.

A header the event carries that `Headers.insert?` rejects is dropped rather than failing the
whole request, matching what the server itself would have done with it off a socket. -/
def requestHeaders (event : Event) : Headers :=
  let fromEvent := event.headers.foldl (init := Headers.empty) fun headers (name, value) =>
    if isAdapterOwned name then headers else (headers.insert? name value).getD headers
  let withCookies :=
    if event.cookies.isEmpty then fromEvent
    else
      let joined := String.intercalate "; " event.cookies.toList
      (fromEvent.insert? "cookie" joined).getD fromEvent
  let withFor := (withCookies.insert? "x-forwarded-for" event.sourceIp).getD withCookies
  (withFor.insert? "x-forwarded-proto" "https").getD withFor

/-- Reuses the server's own request-target parser rather than assembling a `URI.Path` and
`URI.Query` by hand, so a path or query string the handler would have rejected off a socket is
rejected here too. -/
def head (event : Event) : Except String Request.Head := do
  let some method := Method.ofString? event.method
    | throw s!"unsupported method: {event.method}"
  let target :=
    if event.rawQueryString.isEmpty then event.rawPath
    else event.rawPath ++ "?" ++ event.rawQueryString
  let uri ←
    match (URI.Parser.parseRequestTarget <* Std.Internal.Parsec.eof).run target.toUTF8 with
    | .ok uri => pure uri
    | .error e => throw s!"invalid request target {target}: {e}"
  pure { method, version := .v11, uri, headers := event.requestHeaders }

def toRequest (event : Event) : Async (Except String (Request Body.Stream)) := do
  match event.head with
  | .error e => pure (.error e)
  | .ok line =>
    let body ← Body.fromBytes event.body
    pure (.ok { line, body })

end Event

/-- Accumulates the body, giving up as soon as it passes what Lambda will accept rather than
buffering a response that can only be rejected once complete. -/
private def collect (body : Body.Any) : Async (Except String ByteArray) := do
  let mut acc := ByteArray.empty
  while true do
    match ← body.recv with
    | none => break
    | some chunk =>
      acc := acc ++ chunk.data
      if acc.size > maxResponseBytes then
        return .error s!"response body exceeds Lambda's {maxResponseBytes} byte limit"
  pure (.ok acc)

private def joinDuplicates (pairs : Array (String × String)) : List (String × Json) :=
  pairs.foldl (init := #[]) (fun acc (name, value) =>
      match acc.findIdx? (·.1 == name) with
      | some i => acc.modify i fun (name, existing) => (name, existing ++ ", " ++ value)
      | none => acc.push (name, value))
    |>.toList.map fun (name, value) => (name, Json.str value)

/-- Lambda turns each entry of the payload's `cookies` array into its own `Set-Cookie` header and
documents that responses must not set the header directly. Leaving them among the headers would
collapse this stack's several cookies into one comma-joined value that no browser will read
back. -/
private def splitCookies (headers : Headers) : Array String × List (String × Json) :=
  let (cookies, rest) := headers.toArray.foldl (init := (#[], #[]))
    fun (cookies, rest) (name, value) =>
      if name == Middleware.Header.Name.setCookie then
        (cookies.push value.value, rest)
      else
        (cookies, rest.push (name.value, value.value))
  (cookies, joinDuplicates rest)

/-- A body that isn't valid UTF-8 goes back base64-encoded. Sending text as text keeps
CloudWatch's record of the response readable, which is worth the branch. -/
def responseToJson (response : Response Body.Any) : Async (Except String Json) := do
  match ← collect response.body with
  | .error e => pure (.error e)
  | .ok bytes =>
    let (cookies, headers) := splitCookies response.line.headers
    let (body, isBase64Encoded) :=
      match String.fromUTF8? bytes with
      | some text => (text, false)
      | none => (Middleware.Crypto.Base64.encode bytes, true)
    pure <| .ok <| Json.mkObj [
      ("statusCode", Json.num response.line.status.toCode.toNat),
      ("headers", Json.mkObj headers),
      ("cookies", Json.arr (cookies.map Json.str)),
      ("body", Json.str body),
      ("isBase64Encoded", Json.bool isBase64Encoded)]

end Lambda
