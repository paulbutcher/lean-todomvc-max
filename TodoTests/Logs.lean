/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Logs
public import TodoTests.Harness

public section

namespace TodoTests

private def row : String :=
  "{\"time\":\"2026-08-21T09:14:02.331000000Z\",\"duration_ms\":8.123456,\"name\":\"solve\"," ++
    "\"trace.trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\"," ++
    "\"trace.span_id\":\"00f067aa0ba902b7\",\"span.kind\":\"internal\",\"status_code\":0," ++
    "\"meta.signal_type\":\"trace\",\"service.name\":\"todomvc\"}"

/-- `sam logs` puts its own stream and timestamp in front of every line, and what a row reads as
cannot depend on whether they are there. A row that failed to parse would fail this too, since
the two lines would then differ by exactly the prefix. -/
private def testThePrefixDoesNotChangeTheRow : IO Unit :=
  checkEq "prefixed row" (Logs.render row)
    (Logs.render ("2026/08/21/[$LATEST]0a1b2c3d 2026-08-21T09:14:02.331000 " ++ row))

/-- A developer tailing a function watches for `START` and `REPORT` as much as for anything the
application says, so a line that is not a row has to survive untouched. -/
private def testWhatIsNotARowIsPassedThrough : IO Unit :=
  let line := "REPORT RequestId: 8f3c1e2a Duration: 12.34 ms Billed Duration: 13 ms"
  checkEq "report line" line (Logs.render line)

def runLogsTests : IO Unit := do
  testThePrefixDoesNotChangeTheRow
  testWhatIsNotARowIsPassedThrough

end TodoTests
