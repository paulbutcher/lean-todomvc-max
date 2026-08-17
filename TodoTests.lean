/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import TodoTests.App
import TodoTests.Db
import TodoTests.Lambda
import TodoTests.Runtime
import TodoTests.Store
import TodoTests.Views

namespace TodoTests

/-- The tests that have to be run. Anything stated as a `theorem` or a `#guard` has already been
checked by the time this builds, so only the ones that need to execute appear here. -/
def runAll : IO Unit := do
  runAppTests
  runLambdaTests
  runRuntimeTests
  runDbTests
  IO.println "All tests passed."

end TodoTests

def main : IO Unit := TodoTests.runAll
