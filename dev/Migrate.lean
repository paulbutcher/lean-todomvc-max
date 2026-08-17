/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Postgres
import Leanmigrate
import LeanmigratePostgres
import Todo.Migrations

def main (args : List String) : IO UInt32 := do
  let conn ← Postgres.open ""
  runCli { conn, dir := Todo.migrationsDir } args
