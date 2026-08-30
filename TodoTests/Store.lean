/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Todo.Store
public meta import Todo.Store

public section

namespace TodoTests

open Todo

#guard normalisedTitle "  Buy milk  " == some "Buy milk"
#guard normalisedTitle "" == none
#guard normalisedTitle "   " == none

/-- Whatever survives normalisation is non-blank, so `none` is the only way for a blank title to
reach `add` and `setTitle`, and each has to decide what to do about it.

`normalisedTitle raw` is what every handler puts a submitted title through, and the hypothesis
`= some title` picks out the case in which it accepts one. `title.isEmpty = false` answers that
the accepted string has at least one character in it, so the blank case cannot arrive by that
route. `raw` is unconstrained, covering a title that is empty, whitespace only, or already clean,
and the hypothesis is met by any of the last kind, so this is not vacuously true. -/
theorem normalisedTitle_ne_blank {raw title : String} (h : normalisedTitle raw = some title) :
    title.isEmpty = false := by
  simp [normalisedTitle] at h
  obtain ⟨blank, rfl⟩ := h
  simpa using blank

end TodoTests
