/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server
import Postgres
import Middleware
import Telemetry.Sdk
import Todo

open Std Async
open Std Http Server
open Telemetry

/-- Enough for the handful of requests a browser opens at once. Unlike the deployed function this
server has no bound on how many requests it will accept concurrently, so the pool is what limits
the connections it asks the database for.

No timeouts in the connection string: a development database is on the same host, so a connection
that stops working does so by being closed, which the pool detects without needing one. A
deployment where something between the two can drop a flow silently has to say so; see
`LambdaMain.conninfo`. -/
private def poolSize : Nat := 8

/-- With nothing in the environment set this installs the console exporter in its readable format,
so a developer gets a trace per request on the terminal and no configuration to do. -/
def main : IO Unit := Async.block do
  Sdk.installFromEnv
  try
    let pool ← Postgres.Pool.create "" poolSize
    runTelemetry (spanning "migrate" (liftM (Postgres.Pool.withConnAsync pool Todo.migrate)))
    let sessions ← Middleware.MemoryStore.new
    let addr := .v4 ⟨.ofParts 127 0 0 1, 0⟩
    let server ← serve addr (Todo.server (Todo.Db.store pool) sessions)
    IO.println s!"Listening on http://{server.localAddr.get!}"
    server.waitShutdown
  finally
    Sdk.shutdown
