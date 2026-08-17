/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std.Async.Basic

open Std.Async (Async)

namespace Todo

structure Item where
  id : Int64
  title : String
  completed : Bool
deriving Repr, BEq

inductive Filter where
  | all
  | active
  | completed
deriving Repr, BEq

/-- `none` for a title that is blank once trimmed. The TodoMVC spec treats such a title as no
title at all: adding one does nothing, and editing an existing one down to blank deletes it. -/
def normalisedTitle (raw : String) : Option String :=
  let title := raw.trimAscii.toString
  if title.isEmpty then none else some title

/-- The storage operations the handlers need, named rather than reached for directly, so that
they can be driven by an in-memory implementation with no database behind it.

`Std.Async.Async` rather than `IO` because an implementation backed by a connection pool has to be
able to wait for a free connection, and a handler is one fiber among many sharing an OS thread:
blocking that thread to wait would stall every unrelated request sharing it. -/
structure Store where
  list : Filter → Async (Array Item)
  add : String → Async Unit
  toggle : Int64 → Async Unit
  delete : Int64 → Async Unit
  setTitle : Int64 → String → Async Unit
  toggleAll : Async Unit
  clearCompleted : Async Unit

end Todo
