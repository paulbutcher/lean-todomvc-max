/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Http.Server
import SQLite
import Todo

open Std Async
open Std Http Server

def main : IO Unit := Async.block do
  let db ← SQLite.open ":memory:"
  Todo.initSchema db
  let addr := .v4 ⟨.ofParts 127 0 0 1, 0⟩
  let server ← serve addr (Todo.app db)
  IO.println s!"Listening on http://{server.localAddr.get!}"
  server.waitShutdown
