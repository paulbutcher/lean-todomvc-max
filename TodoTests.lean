/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import TodoTests.App
public import TodoTests.Auth
public import TodoTests.Db
public import TodoTests.Logs
public import TodoTests.Store
public import TodoTests.Tracing
public import TodoTests.Views

public section

namespace TodoTests

/-- The tests that have to be run. Anything stated as a `theorem` or a `#guard` has already been
checked by the time this builds, so only the ones that need to execute appear here. -/
def runAll : IO Unit := do
  runAppTests
  runAuthTests
  runTracingTests
  runLogsTests
  runDbTests
  IO.println "All tests passed."

end TodoTests

def main : IO Unit := TodoTests.runAll
