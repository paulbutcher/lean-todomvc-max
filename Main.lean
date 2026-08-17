/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server
import Postgres
import Middleware
import Todo

open Std Async
open Std Http Server

def main : IO Unit := Async.block do
  let db ← Postgres.open ""
  Todo.migrate db
  let sessions ← Middleware.MemoryStore.new
  let addr := .v4 ⟨.ofParts 127 0 0 1, 0⟩
  let server ← serve addr (Todo.server (Todo.Db.store db) sessions)
  IO.println s!"Listening on http://{server.localAddr.get!}"
  server.waitShutdown
