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

/-- The point of a silent sign-in response: the outcomes that identify a person are
indistinguishable from a link having been sent, so asking after somebody else's address teaches
nothing about whether they have an account.

`Todo.Auth.messageFor` is what the sign-in form is answered with, and `.checkYourMail` is the
answer that says nothing, so the hypothesis picks out every outcome the person is told anything
else about. The conclusion admits exactly two of them, and both describe the request rather than
the requester: `.throttled` says this address has been asked after recently, `.malformedAddress`
says what was typed does not parse. `outcome` ranges over the whole of `SignInOutcome` rather than
over a list of the cases that matter today, so a case added to the library has to be answered here
rather than defaulting into a leak. -/
theorem onlySpeaksAboutTheRequest (outcome : Authentication.SignInOutcome) :
    Todo.Auth.messageFor outcome ≠ .checkYourMail →
      outcome = .throttled ∨ outcome = .malformedAddress := by
  cases outcome <;> simp [Todo.Auth.messageFor]

def runAuthTests : IO Unit := runGroup "Todo.Auth" testEverySendAsksAgain

end TodoTests
