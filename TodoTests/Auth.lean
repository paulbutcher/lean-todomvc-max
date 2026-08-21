/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.Auth
public import TodoTests.Harness

public section

namespace TodoTests

open Authentication
open Std.Http.Internal.Test

private def message (subject : String) : OutboundEmail :=
  { «from» :=
      { address := ⟨"no-reply", ⟨["todomvc", "example"]⟩⟩, displayName := "todos" }
    to := ⟨"alice", ⟨["example", "com"]⟩⟩
    subject
    textBody := "a link"
    idempotencyKey := subject }

/-- A transport built once holds the credential it was built with, and the credentials a role is
given expire. Nothing about a send that reuses a stale one looks wrong until it starts failing,
hours after the process it was built in started, so the promise worth pinning down is that every
send asks again. -/
private def testEverySendAsksAgain : IO Unit := do
  let drawn ← IO.mkRef 0
  let used ← IO.mkRef (#[] : Array Nat)
  let transport := Todo.Auth.refreshing (drawn.modifyGet fun n => (n, n + 1)) fun credential =>
    { send := fun mail => do
        used.modify (·.push credential)
        pure (.ok ⟨mail.idempotencyKey⟩) }
  discard <| transport.send (message "one")
  discard <| transport.send (message "two")
  checkEq "each send drew a credential of its own" #[0, 1] (← used.get)

def runAuthTests : IO Unit := runGroup "Todo.Auth" testEverySendAsksAgain

end TodoTests
