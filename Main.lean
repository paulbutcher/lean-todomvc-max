/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Server
public import Postgres
public import Middleware
public import Telemetry.Sdk
public import Todo

public section

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

/-- Fixed, unlike the port this used to bind, because a magic link has to name an origin a
browser can come back to and the mail is written before the listener exists. -/
def port : IO UInt16 := do
  match ← IO.getEnv "PORT" with
  | none => pure 8080
  | some raw =>
    match raw.toNat? with
    | some value => pure value.toUInt16
    | none => throw (IO.userError s!"PORT is {raw}, which is not a number")

/-- Not a secret, and deliberately so: the transport below prints every sign-in link to this same
terminal, so nothing here is protecting anything. Being fixed rather than drawn per process is
what lets a session outlive a restart, which is the whole point of it during development. The
deployed function takes its own from the environment and will not start without one. -/
def developmentPepper : Authentication.Pepper :=
  { keyId := ⟨"development"⟩, secret := "todomvc-development-pepper".toUTF8 }

/-- With nothing in the environment set this installs the console exporter in its readable format,
so a developer gets a trace per request on the terminal and no configuration to do. -/
def main : IO Unit := Async.block do
  Sdk.installFromEnv
  try
    let port ← port
    let pool ← Postgres.Pool.create "" poolSize
    runTelemetry (spanning "migrate" (liftM (Postgres.Pool.withConnAsync pool Todo.migrate)))
    let sessions ← Middleware.MemoryStore.new
    let site := Todo.Auth.site pool
      { pepper := developmentPepper
        baseUrl := ⟨s!"http://localhost:{port}"⟩
        sender :=
          { address := ⟨"no-reply", ⟨["todomvc", "example"]⟩⟩, displayName := "todos" }
        transport := Authentication.EmailTransport.console }
    let addr := .v4 ⟨.ofParts 127 0 0 1, port⟩
    let server ← serve addr
      (Todo.server site.identity site.handler (Todo.Db.store pool) sessions)
    IO.println s!"Listening on http://{server.localAddr.get!}"
    server.waitShutdown
  finally
    Sdk.shutdown
