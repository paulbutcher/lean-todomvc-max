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
