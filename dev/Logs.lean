/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Telemetry.Parse
public import Telemetry.Sdk

public section

open Telemetry

namespace Logs

/-- `sam logs` prefixes each line with its stream and timestamp, so a row starts at the first
brace. The prefix is dropped once a row parses, because the row carries its own time and names
the execution environment it came from in `faas.instance`.

Anything that is not a row is passed through untouched, which is what keeps `START`, `END` and
`REPORT` visible. -/
def render (line : String) : String :=
  match Parse.Flat.parse (line.dropWhile (· != '{')).toString with
  | .ok (.span data) => Sdk.Console.renderSpan data
  | .ok (.log record) => Render.logRecord record
  | .error _ => line

end Logs
