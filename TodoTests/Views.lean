/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Html
public import Todo.Views
public meta import Todo.Views
public meta import Todo.Store

public section

namespace TodoTests

open Todo Html

#guard filterFromPath (Filter.path .all) == .all
#guard filterFromPath (Filter.path .active) == .active
#guard filterFromPath (Filter.path .completed) == .completed
#guard filterFromPath "http://localhost:2000/completed" == .completed
#guard filterFromPath "/garbage" == .all

#guard countLabel 0 == "0 items left"
#guard countLabel 1 == "1 item left"
#guard countLabel 2 == "2 items left"

/-- A page carries an `hx-headers` attribute exactly when there is a token to put in it: never
announcing a token it doesn't have, and never silently dropping one it does (which would make
every mutation from that page fail anti-forgery validation). -/
theorem csrfAttrs_nonempty_iff (token : Option String) :
    (csrfAttrs token).isEmpty = token.isNone := by
  cases token <;> rfl

end TodoTests
