/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.Federation
public import TodoTests.Harness

public section

namespace TodoTests

open Authentication
open Std.Http.Internal.Test

private def lookup (entries : List (String × String)) : Todo.Federation.Lookup :=
  fun name => pure ((entries.find? (·.1 == name)).map (·.2))

/-- Sealed under a key this test does not hold. Nothing here opens one, which is the point: what
is under test is whether a secret can be read as a secret at all, and that is settled by its
shape rather than by the key it was sealed with. -/
private def sealedSecret : String :=
  "v1.s.c2VhbGluZy0yMDI2LTAx.pw2Wl90qApf-jU7m.-2TIdVhObVO1CGu6uvLjbFlzabF0A3LgHWY.\
   ngQGZSuINZdPlKSrupAaGw"

private def sealingKey : List (String × String) :=
  [ ("AUTH_SEALING_KEY", "g7YHyG-dAIY4qSgja_qgeDJxdb6aZZuIJnEeS0n6glY"),
    ("AUTH_SEALING_KEY_ID", "sealing-2026-01") ]

private def threw (attempt : IO α) : IO Bool := do
  match ← (try pure (some (← attempt)) catch _ => pure none) with
  | some _ => pure false
  | none => pure true

/-- A deployment that named no provider offers the magic link and nothing else, and must not be
made to hold a sealing key it has nothing to open. -/
private def testNothingConfigured : IO Unit := do
  checkEq "no provider named is no federation" true
    (← Todo.Federation.fromLookup (lookup [])).isNone

/-- One provider turns on without the others, which is what lets a deployment add them one at a
time rather than all at once. -/
private def testOneProvider : IO Unit := do
  let settings ← Todo.Federation.fromLookup (lookup
    ([("GOOGLE_CLIENT_ID", "1234.apps.googleusercontent.com"),
      ("GOOGLE_CLIENT_SECRET", sealedSecret)] ++ sealingKey))
  checkEq "the named provider, and only it" ["google"]
    ((settings.map (·.providers.map (·.id.value))).getD [])

/--
A provider named and then misconfigured refuses to start.

This is the failure the `Option` it is read through invites: `parse` answers `none` for a secret
that cannot be read, and reading that as "no provider was asked for" would deploy cleanly, serve
a sign-in page with a button missing, and tell nobody. Each of the three shapes is a way to get
there, and a malformed secret is the one most likely to arrive from a copy that lost a character.
-/
private def testMisconfiguredRefuses : IO Unit := do
  let named := [("GITHUB_CLIENT_ID", "Iv1.0123456789abcdef")]
  checkEq "a secret that will not parse" true
    (← threw (Todo.Federation.fromLookup (lookup
      (named ++ [("GITHUB_CLIENT_SECRET", "not-a-sealed-secret")] ++ sealingKey))))
  checkEq "no secret at all" true
    (← threw (Todo.Federation.fromLookup (lookup (named ++ sealingKey))))
  checkEq "a provider but no sealing key" true
    (← threw (Todo.Federation.fromLookup (lookup
      (named ++ [("GITHUB_CLIENT_SECRET", sealedSecret)]))))

/-- Apple takes three further values, and each of them missing is a refusal of its own: a signing
key is useless without the two identifiers that say which key it is. -/
private def testAppleNeedsItsIdentifiers : IO Unit := do
  let full :=
    [ ("APPLE_CLIENT_ID", "com.example.service"), ("APPLE_TEAM_ID", "TEAM123456"),
      ("APPLE_KEY_ID", "KEY7890AB"), ("APPLE_SIGNING_KEY", sealedSecret) ] ++ sealingKey
  checkEq "all of them is a provider" false
    (← Todo.Federation.fromLookup (lookup full)).isNone
  for dropped in ["APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_SIGNING_KEY"] do
    checkEq s!"without {dropped}" true
      (← threw (Todo.Federation.fromLookup (lookup (full.filter (·.1 != dropped)))))

/-- An empty value is a stack parameter left at its default, which arrives as an empty string
rather than as nothing at all. Reading one as a configured provider would make every deployment
that ignored these variables fail to start. -/
private def testEmptyIsUnset : IO Unit := do
  checkEq "an empty client id names no provider" true
    (← Todo.Federation.fromLookup (lookup [("GOOGLE_CLIENT_ID", "")])).isNone

def runFederationTests : IO Unit :=
  runGroup "Todo.Federation" do
    testNothingConfigured
    testOneProvider
    testMisconfiguredRefuses
    testAppleNeedsItsIdentifiers
    testEmptyIsUnset

end TodoTests
