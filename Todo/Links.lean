/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Routing.RouteTable

routeTable! Routes
  [ index           := "/",
    active          := "/active",
    completed       := "/completed",
    todos           := "/todos",
    todo            := "/todos/:id:Nat",
    edit            := "/todos/:id:Nat/edit",
    toggle          := "/todos/:id:Nat/toggle",
    toggleAll       := "/todos/toggle-all",
    clearCompleted  := "/todos/clear-completed" ]
