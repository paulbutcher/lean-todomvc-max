/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import MiddlewareAssets

public section

open Html

namespace Todo

/-- Every file this application serves itself, already under the path its digest gives it.

One value carries both halves: `served` is what answers a request for one of these paths, and the
rest is what the pages render. Nothing else knows an asset's name, so the two cannot disagree
about what it is called, which is what makes the far-future policy on those paths safe.

The pages take this rather than `served` alone so that rendering one cannot fail: a name that is
not there is settled at startup instead of in the middle of a page. -/
structure Assets where
  served : Middleware.Assets
  favicon : LinkAttrs
  /-- What the sign-in pages and the connect page need beyond todomvc-app-css, which styles a
  list and not prose. -/
  authCss : LinkAttrs
  /-- The panel and the split it sits in. Separate from the unmodified TodoMVC stylesheet, which
  is left that way: the list still has to look like the one the spec describes, and everything
  here is around it rather than in it. -/
  chatCss : LinkAttrs
  chatScript : ScriptAttrs
  /-- The copy button on the connect page, the one thing on any of these pages a browser cannot
  do without being told how. -/
  connectScript : ScriptAttrs

namespace Assets

/-- Refuses rather than falling back to the plain path.

`path?` answers `none` for a file that was not loaded, and `file` beneath still serves the
unfingerprinted path, so the fallback would work and would then be cached for a year under a name
nothing can change. An image that shipped without `public` is better off not starting.

The message names the file rather than the caller: whoever reads it is looking at a build. -/
private def path (a : Middleware.Assets) (logical : String) : IO String := do
  let some served := a.path? logical
    | throw (IO.userError s!"public/{logical} is not in this build")
  pure served

def load (root : System.FilePath) : IO Assets := do
  let served ← Middleware.Assets.load root
  pure
    { served
      favicon := { rel := "icon", href := ← path served "favicon.svg" }
      authCss := { rel := "stylesheet", href := ← path served "auth.css" }
      chatCss := { rel := "stylesheet", href := ← path served "chat.css" }
      chatScript := { src := ← path served "chat.js" }
      connectScript := { src := ← path served "connect.js" } }

end Assets

end Todo
