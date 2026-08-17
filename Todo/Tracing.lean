/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server
import Middleware
import Telemetry

open Std.Http
open Std.Http.Server
open Telemetry

namespace Todo

/-- The span a request is running under, for handing to a `Store` operation so that its spans
become children of it. `none` when no SDK is installed, which is what makes an uninstrumented
build cost nothing. -/
def parentSpan (req : Request Body.Stream) : Option SpanContext :=
  req.extensions.get SpanContext

/--
A `server` span around every request, published to the request's `extensions` so that anything
below can open children of it.

`routeName` is asked for the matched route template, which is what `http.route` wants and what the
span is worth naming by. A parameter rather than a call into a router, because the span is the
same span whatever matched the request. It is handed the *response* extensions: a router below has
already been given its request by the time it decides what matched, so the response is the only
channel that travels back up to here.

The status code is set only from a response that actually arrived, so a request that ended in an
exception carries status `error` and no code. That is why this belongs inside `Middleware.catchAll`
rather than outside it: an exception reaches this span, and `span` records the message it carried,
before `catchAll` turns it into a `500` that says only that something went wrong.
-/
def serverSpan (routeName : Extensions → Option String) : Middleware := fun handler =>
  { handler with
    onRequest := fun req => runTelemetry do
      let method := toString req.line.method
      span method (kind := .server)
          (attrs := [(Conventions.httpRequestMethod, method),
                     (Conventions.urlPath, toString req.line.uri.path)])
        fun current => do
          let req := match current.context with
            | some ctx => { req with extensions := req.extensions.insert ctx }
            | none => req
          let response ← handler.onRequest req
          let code := response.line.status.toCode
          current.add [(Conventions.httpResponseStatusCode, code.toNat)]
          if let some route := routeName response.extensions then
            current.add [(Conventions.httpRoute, route)]
            current.rename s!"{method} {route}"
          -- A 4xx is the client sending something wrong, not the server failing to serve it.
          if code ≥ 500 then
            current.setStatus .error none
          return response }

end Todo
