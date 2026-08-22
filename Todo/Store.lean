/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Std.Async.Basic
public import Telemetry
public import Todo.Tenant

@[expose] public section

open Std.Async (Async)
open Telemetry (TelemetryT)

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
blocking that thread to wait would stall every unrelated request sharing it.

`TelemetryT` over that because `Std.Http.Server` fixes the monad a handler runs in, so there is
nowhere for the span an operation should hang under to travel implicitly. The reader layer here is
how a caller names it; a caller with nothing to say passes `none` and the operation's own spans
become roots.

Every operation names the account, mutations included, so an id belonging to somebody else
matches nothing rather than being reached by whoever guesses it. -/
structure Store where
  list : Account → Filter → TelemetryT Async (Array Item)
  add : Account → String → TelemetryT Async Unit
  toggle : Account → Int64 → TelemetryT Async Unit
  delete : Account → Int64 → TelemetryT Async Unit
  setTitle : Account → Int64 → String → TelemetryT Async Unit
  setCompleted : Account → Int64 → Bool → TelemetryT Async Unit
  toggleAll : Account → TelemetryT Async Unit
  clearCompleted : Account → TelemetryT Async Unit

end Todo
