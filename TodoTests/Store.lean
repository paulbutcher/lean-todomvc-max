/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Todo.Store

namespace TodoTests

open Todo

#guard normalisedTitle "  Buy milk  " == some "Buy milk"
#guard normalisedTitle "" == none
#guard normalisedTitle "   " == none

/-- Whatever survives normalisation is non-blank, so `none` is the only way for a blank title to
reach `add` and `setTitle`, and each has to decide what to do about it. -/
theorem normalisedTitle_ne_blank {raw title : String} (h : normalisedTitle raw = some title) :
    title.isEmpty = false := by
  simp [normalisedTitle] at h
  obtain ⟨blank, rfl⟩ := h
  simpa using blank

end TodoTests
