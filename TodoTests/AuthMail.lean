/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.AuthMail
public import TodoTests.Harness
public meta import Todo.AuthMail

public section

namespace TodoTests

open Authentication
open Std.Http.Internal.Test

-- A day and an hour either side of ten, and a date only a leap year has, which is where a
-- calendar conversion and a padded field go wrong if they are going to.
#guard Todo.AuthMail.inWords ⟨1755870180⟩ == "22 August 2025 at 13:43 UTC"
#guard Todo.AuthMail.inWords ⟨1767585420⟩ == "5 January 2026 at 03:57 UTC"
#guard Todo.AuthMail.inWords ⟨1709208000⟩ == "29 February 2024 at 12:00 UTC"

private def contains (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

private def magicLink : String :=
  "https://todomvc.example/t/todomvc/signin/link?token=8f2b1c9d4e5a6b7c8d9e0f1a2b3c4d5e"

private def request : SignInDetails :=
  { tenantName := "TodoMVC"
    recipient := ⟨"alice", ⟨["example", "com"]⟩⟩
    magicLink
    emailedCode := none
    requester := { ip := some "203.0.113.7" }
    requestedAt := ⟨1755870180⟩ }

private def html (mail : RenderedEmail) : String := mail.htmlBody.getD ""

/-- Both parts, because a client shows one or the other and there is no signing in from the one
that lost the link. The address is there so that somebody with more than one can tell which of
them this is about. -/
private def testBothPartsCarryTheLink : IO Unit := do
  let mail := Todo.AuthMail.templates.signIn request
  checkEq "the text part carries the link" true (contains mail.textBody magicLink)
  checkEq "the html part carries the link" true (contains (html mail) magicLink)
  checkEq "the text part names the address" true (contains mail.textBody "alice@example.com")
  checkEq "the html part names the address" true (contains (html mail) "alice@example.com")

/-- Whoever reads this has to recognise the moment as one they were there for, and epoch seconds,
which is what the attempt records and what the library's own template states, name it exactly
and say nothing. -/
private def testTheTimeIsInWords : IO Unit := do
  let mail := Todo.AuthMail.templates.signIn request
  checkEq "the mail says when it was asked for" true
    (contains mail.textBody "22 August 2025 at 13:43 UTC")
  checkEq "and not in epoch seconds" false (contains mail.textBody "1755870180")

/-- Nothing about a code unless one was sent: an instruction to type something that never
arrived sends whoever reads it looking for a second mail that does not exist. -/
private def testTheCodeAppearsOnlyWhenOneWasSent : IO Unit := do
  let silent := Todo.AuthMail.templates.signIn request
  checkEq "the text part does not mention a code" false (contains silent.textBody "code")
  checkEq "nor does the html part" false (contains (html silent) "code")
  let spoken := Todo.AuthMail.templates.signIn { request with emailedCode := some "K7M2-QP94" }
  checkEq "the text part carries the code" true (contains spoken.textBody "K7M2-QP94")
  checkEq "the html part carries the code" true (contains (html spoken) "K7M2-QP94")

def runAuthMailTests : IO Unit :=
  runGroup "Todo.AuthMail" do
    testBothPartsCarryTheLink
    testTheTimeIsInWords
    testTheCodeAppearsOnlyWhenOneWasSent

end TodoTests
