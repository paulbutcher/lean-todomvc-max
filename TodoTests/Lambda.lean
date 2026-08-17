/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lambda
import Middleware

namespace TodoTests

open Lambda
open Lean (Json)
open Std Async
open Std Http
open Std Http Server

/-- A function URL event, in the shape AWS documents for payload format 2.0. The client has
supplied both a `Cookie` header and an `X-Forwarded-For` that disagree with what the request
context reports, which is the case the adapter exists to get right. -/
private def spoofedEvent : String :=
  "{\"version\":\"2.0\",\"rawPath\":\"/active\",\"rawQueryString\":\"show=all&n=2\"," ++
  "\"cookies\":[\"todomvc-session=abc\",\"other=1\"]," ++
  "\"headers\":{\"host\":\"id.lambda-url.eu-west-1.on.aws\",\"x-forwarded-for\":\"10.0.0.1\"," ++
  "\"x-forwarded-proto\":\"http\",\"cookie\":\"todomvc-session=forged\"," ++
  "\"hx-current-url\":\"http://example.com/active\"}," ++
  "\"requestContext\":{\"http\":{\"method\":\"POST\",\"path\":\"/active\"," ++
  "\"protocol\":\"HTTP/1.1\",\"sourceIp\":\"203.0.113.7\",\"userAgent\":\"agent\"}}," ++
  "\"body\":\"title=Buy+milk\",\"isBase64Encoded\":false}"

private def parseEvent (text : String) : Except String Event := do
  Event.ofJson (← Json.parse text)

private def headerOf (text : String) (name : String) : Option String := do
  let event := (parseEvent text).toOption
  let name ← Header.Name.ofString? name
  ((← event).requestHeaders.get? name).map (·.value)

-- The address the handler sees is the one AWS reports, not the one the caller asked for.
#guard headerOf spoofedEvent "x-forwarded-for" == some "203.0.113.7"

-- A function URL has no plaintext listener, whatever the event's own header claims.
#guard headerOf spoofedEvent "x-forwarded-proto" == some "https"

-- Payload format 2.0 puts request cookies in `cookies` and omits the header, so the header the
-- session and anti-forgery middleware read has to be rebuilt from that array alone.
#guard headerOf spoofedEvent "cookie" == some "todomvc-session=abc; other=1"

-- Headers the adapter has no opinion about still reach the handler.
#guard headerOf spoofedEvent "hx-current-url" == some "http://example.com/active"

private def targetOf (text : String) : Option String := do
  let event ← (parseEvent text).toOption
  ((Event.head event).map (toString ·.uri)).toOption

#guard targetOf spoofedEvent == some "/active?show=all&n=2"

private def methodOf (text : String) : Option Method := do
  let event ← (parseEvent text).toOption
  ((Event.head event).map (·.method)).toOption

#guard methodOf spoofedEvent == some .post

/-- No value the caller puts in the event's header map can reach the handler under a name the
adapter sets for itself. Stated over an arbitrary trailing header because that is the shape of
the attack: `x-forwarded-for` arrives already truncated by the function URL to the single,
caller-chosen entry that `Middleware.forwardedRemoteAddr` would otherwise read back. -/
theorem requestHeaders_ignores_client_values (event : Event) (name value : String)
    (owned : Event.isAdapterOwned name) :
    Event.requestHeaders { event with headers := event.headers.push (name, value) }
      = Event.requestHeaders event := by
  simp [Event.requestHeaders, owned]

#guard (Endpoint.ofString "127.0.0.1:9001").map (·.addr) == some (.v4 ⟨.ofParts 127 0 0 1, 9001⟩)

-- The `Host` header has to echo the endpoint exactly as the environment advertised it.
#guard (Endpoint.ofString "127.0.0.1:9001").map (·.host) == some "127.0.0.1:9001"

#guard (Endpoint.ofString "127.0.0.1").isNone
#guard (Endpoint.ofString "127.0.0.1:70000").isNone
#guard (Endpoint.ofString "127.0.0.256:9001").isNone

-- Only a literal address is understood, so a name has to be rejected rather than half-parsed.
#guard (Endpoint.ofString "localhost:9001").isNone

#guard (ofHex? "00ff10").map (·.toList) == some [0, 255, 16]
#guard (ofHex? "DeadBeef").map (·.toList) == some [222, 173, 190, 239]
#guard (ofHex? "").map (·.size) == some 0
#guard (ofHex? "abc").isNone
#guard (ofHex? "zz").isNone

-- `template.yaml` generates the session key as 64 hex characters because that is what AES-256's
-- 32 byte key comes to; if either number moves without the other, sessions stop being readable.
#guard (ofHex? (String.mk (List.replicate 64 'a'))).map (·.size) == some 32

private def checkEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit :=
  unless expected == actual do
    throw <| IO.userError s!"{label}: expected {repr expected}, got {repr actual}"

private def bodyOf (text : String) : IO String := do
  let .ok event := parseEvent text | throw (IO.userError s!"could not parse event: {text}")
  pure (String.fromUTF8? event.body |>.getD "<not utf-8>")

/-- `title=Buy+milk`, base64-encoded. -/
private def base64Event : String :=
  "{\"version\":\"2.0\",\"rawPath\":\"/\",\"rawQueryString\":\"\",\"headers\":{}," ++
  "\"requestContext\":{\"http\":{\"method\":\"POST\",\"sourceIp\":\"203.0.113.7\"}}," ++
  "\"body\":\"dGl0bGU9QnV5K21pbGs=\",\"isBase64Encoded\":true}"

private def testBodies : IO Unit := do
  checkEq "plain body" "title=Buy+milk" (← bodyOf spoofedEvent)
  checkEq "base64 body" "title=Buy+milk" (← bodyOf base64Event)

#eval testBodies

private def field (payload : Json) (name : String) : String :=
  ((payload.getObjVal? name).toOption.getD .null).compress

/-- Lambda turns each entry of `cookies` into its own `Set-Cookie` header and rejects responses
that set the header directly, so a stack that sets several cookies depends on them being moved
across rather than left to collapse into one comma-joined header value. -/
private def testResponseCookies : IO Unit := do
  let headers := Headers.empty
    |>.insert Middleware.Header.Name.setCookie (.mk "todomvc-session=abc; Path=/")
    |>.insert Middleware.Header.Name.setCookie (.mk "csrf=xyz; Path=/")
    |>.insert Header.Name.contentType (.mk "text/html")
  let response : Response Body.Any :=
    { line := { status := .ok, version := .v11, headers }, body := Body.Any.ofBody ({} : Body.Empty) }
  let .ok payload ← Async.block (responseToJson response)
    | throw (IO.userError "response could not be encoded")
  checkEq "both cookies move to the payload's cookies array"
    "[\"todomvc-session=abc; Path=/\",\"csrf=xyz; Path=/\"]" (field payload "cookies")
  checkEq "no set-cookie is left among the headers"
    "{\"content-type\":\"text/html\"}" (field payload "headers")
  checkEq "the status travels as a number" "200" (field payload "statusCode")

#eval testResponseCookies

end TodoTests
