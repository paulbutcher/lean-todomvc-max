/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Http.Test.Helpers
public import Todo.Assets
public import TodoTests.Harness

public section

namespace TodoTests

open Todo
open Std.Http.Internal.Test

private def threw (attempt : IO α) : IO Bool := do
  match ← (try pure (some (← attempt)) catch _ => pure none) with
  | some _ => pure false
  | none => pure true

/-- Every file the pages name is under `public`, and a build where one is not refuses to start.

This is the `Option` `path?` is read through: it answers `none` for a file that was never loaded,
and `file` underneath still serves the plain path, so reading `none` as "use that instead" would
start cleanly and then pin the wrong bytes for a year under a name nothing can change. What makes
it worth a test rather than a comment is that renaming a file under `public` is a change nothing
else would object to. -/
private def testEveryNamedFileIsThere : IO Unit := do
  checkEq "the real directory" false (← threw (Assets.load "public"))
  let missing ← IO.FS.createTempDir
  try
    for name in ["favicon.svg", "auth.css", "chat.css", "chat.js"] do
      IO.FS.writeFile (missing / name) ""
    checkEq "one file short" true (← threw (Assets.load missing))
  finally
    IO.FS.removeDirAll missing

/-- The path a page renders is the path the middleware answers to, for every asset at once.

Rendering and serving read one value, so this cannot fail while that holds; what it guards is
somebody reaching past it later and giving the pages a path of their own. -/
private def testRenderedPathsAreServed : IO Unit := do
  let assets ← Assets.load "public"
  let rendered :=
    [assets.favicon.href, assets.authCss.href, assets.chatCss.href,
     assets.chatScript.src, assets.connectScript.src]
  for path in rendered do
    checkEq s!"{path} is served" true (assets.served.entry? path).isSome

def runAssetsTests : IO Unit :=
  runGroup "Todo.Assets" do
    testEveryNamedFileIsThere
    testRenderedPathsAreServed

end TodoTests
