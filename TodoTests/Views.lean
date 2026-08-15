/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Html
import Todo.Views

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

end TodoTests
