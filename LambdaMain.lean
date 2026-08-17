/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lambda
import Middleware
import MiddlewareCookieStore
import Postgres
import Todo

open Std Async

/-- The key has to outlive any one execution environment. Letting `CookieStore` mint its own
would give each concurrently running instance a different one, so a session sealed by whichever
instance served the page would be unreadable by whichever instance served the next request, and
`antiForgery` would reject every mutation. -/
def sessionStore : IO Middleware.CookieStore := do
  let some encoded ← IO.getEnv "SESSION_KEY"
    | throw (IO.userError "SESSION_KEY is not set")
  let some key := Lambda.ofHex? encoded
    | throw (IO.userError "SESSION_KEY is not an even-length run of hex digits")
  if key.size != 32 then
    throw (IO.userError s!"SESSION_KEY decodes to {key.size} bytes, but AES-256 needs 32")
  Middleware.CookieStore.new { key := some key }

/-- Anything that fails before the first invocation is reported to the runtime API's init
endpoint rather than just logged, so the environment is torn down immediately instead of
accepting an invocation it has no working database connection to serve. -/
def main : IO Unit := Async.block do
  let some advertised ← IO.getEnv "AWS_LAMBDA_RUNTIME_API"
    | throw (IO.userError "AWS_LAMBDA_RUNTIME_API is not set")
  let some endpoint := Lambda.Endpoint.ofString advertised
    | throw (IO.userError s!"AWS_LAMBDA_RUNTIME_API is not a host:port address: {advertised}")
  let started ←
    try
      let db ← Postgres.open ""
      Todo.Db.initSchema db
      let sessions ← sessionStore
      pure (Except.ok (Todo.server (Todo.Db.store db) sessions))
    catch e =>
      pure (Except.error (toString e))
  match started with
  | .error e =>
    discard <| (Lambda.postInitError endpoint e).run
    throw (IO.userError e)
  | .ok handler =>
    Lambda.run handler endpoint
