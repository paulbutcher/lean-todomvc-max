/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Logs

public section

/-- Reading the deployed function's telemetry in the form a terminal wants:

```
sam logs --stack-name todomvc --tail | lake exe logs
```

The deployment writes `flat_json`, which is what makes the telemetry queryable and what makes it
unreadable. This renders it back through the same `Telemetry.Render` the application prints
directly when it runs locally, so the two are the same output. -/
def main : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  let mut line ← stdin.getLine
  while !line.isEmpty do
    stdout.putStrLn (Logs.render line.trimAsciiEnd.toString)
    -- Tailing a stream that stalls in a buffer defeats the point of tailing it.
    stdout.flush
    line ← stdin.getLine
