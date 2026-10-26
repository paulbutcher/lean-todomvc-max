/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Postgres
public import Leanmigrate
public import LeanmigratePostgres

public section

namespace Todo

/-- Resolved against the working directory, which is the repository root during development and
`/var/task` in the deployed image. -/
def migrationsDir : System.FilePath := "migrations"

/-- Read where Lake fetched the package rather than copied into `migrationsDir`, so that taking a
version of the library means taking its migrations too. The image puts them at the same relative
path. -/
def authenticationMigrationsDir : System.FilePath :=
  ".lake/packages/authentication/migrations/postgres"

/-- Both sets, in the one id order they were written in, since a migration of ours may name a
table one of the library's created.

`discoverMigrations` treats a missing directory as holding nothing, which for the library's would
start a process against a schema missing every table it added. An id found in both is a copy left
behind in `migrationsDir`, and would be applied once while seeming to be two. -/
def migrations : IO (Array Migration) := do
  unless ← authenticationMigrationsDir.isDir do
    throw (IO.userError s!"{authenticationMigrationsDir} is not in this build")
  let ours ← discoverMigrations migrationsDir
  let theirs ← discoverMigrations authenticationMigrationsDir
  for m in ours do
    if theirs.any (·.id == m.id) then
      throw (IO.userError s!"migration {m.id} is in both {migrationsDir} and \
        {authenticationMigrationsDir}")
  pure ((ours ++ theirs).qsort (·.id < ·.id))

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
    migrateUp db (← migrations)
  finally
    Postgres.execScript db s!"SELECT pg_advisory_unlock({migrationLockKey})"

end Todo
