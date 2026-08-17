/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Postgres
import Leanmigrate
import LeanmigratePostgres

namespace Todo

/-- Resolved against the working directory, which is the repository root during development and
`/var/task` in the deployed image. -/
def migrationsDir : System.FilePath := "migrations"

/-- Any value will do, as long as every instance uses the same one. -/
private def migrationLockKey : Int := 1970825044

/-- Brings the database up to date, one caller at a time. A deploy can start many instances at
once, and without the lock two of them racing to apply the same migration would have one of them
fail: `CREATE TABLE IF NOT EXISTS` is not safe against a concurrent copy of itself, and the
loser's bookkeeping row collides with the winner's on the way in. Whoever waits finds nothing
left to do. -/
def migrate (db : Postgres.Conn) : IO Unit := do
  Postgres.execScript db s!"SELECT pg_advisory_lock({migrationLockKey})"
  try
    migrateUp db (← discoverMigrations migrationsDir)
  finally
    Postgres.execScript db s!"SELECT pg_advisory_unlock({migrationLockKey})"

end Todo
