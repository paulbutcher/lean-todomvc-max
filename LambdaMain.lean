/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import AwsLambdaHttp
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
  let some key := AwsLambda.ofHex? encoded
    | throw (IO.userError "SESSION_KEY is not an even-length run of hex digits")
  if key.size != 32 then
    throw (IO.userError s!"SESSION_KEY decodes to {key.size} bytes, but AES-256 needs 32")
  Middleware.CookieStore.new { key := some key }

/-- Only timeouts: everything identifying the database comes from the `PG*` variables the
deployment sets, and libpq has no environment variable for either of these.

`tcp_user_timeout` is what makes a broken connection discoverable here at all. The execution
environment is frozen between invocations, so a connection can be silently dropped by the network
in front of it with no close ever delivered; without a bound the operating system retransmits for
several minutes, far longer than the function's own timeout. Keepalives are the usual companion to
this and are deliberately absent: nothing can be sent while the environment is frozen, which is
precisely the period the flow goes away in.

Both are well inside the function timeout even if a borrow has to wait out one and then open a
fresh connection. -/
def conninfo : String := "connect_timeout=5 tcp_user_timeout=5000"

/-- Lambda runs one invocation at a time per execution environment, and the runtime serves them
sequentially, so one connection is all that can ever be in use. Capacity here is multiplied by the
function's reserved concurrency to give the load the database sees, which is the reason not to
round it up for comfort. -/
def poolSize : Nat := 1

/-- Anything raised here happens before the first invocation, and `AwsLambda.serve` reports it to
the runtime API's init endpoint rather than just logging it, so the environment is torn down
immediately instead of accepting an invocation it has no working database connection to serve. -/
def main : IO Unit := AwsLambda.serve do
  let pool ← Postgres.Pool.create conninfo poolSize
  Postgres.Pool.withConnAsync pool Todo.migrate
  let sessions ← sessionStore
  -- A function URL is reachable over https only, so TLS termination is a given here.
  pure (AwsLambda.Http.handler (Todo.server (Todo.Db.store pool) sessions (https := true)))
