/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Routing.RouteTable

@[expose] public section

route_table Routes
  [ index           := "/",
    active          := "/active",
    completed       := "/completed",
    todos           := "/todos",
    todo            := "/todos/:id:Nat",
    edit            := "/todos/:id:Nat/edit",
    toggle          := "/todos/:id:Nat/toggle",
    toggleAll       := "/todos/toggle-all",
    clearCompleted  := "/todos/clear-completed",
    signOut         := "/signout",
    chat            := "/chat",
    chatStatus      := "/chat/status",
    todosStatus     := "/todos/status",
    mcp             := "/mcp",
    oauthAuthorize  := "/oauth/authorize",
    oauthToken      := "/oauth/token",
    oauthRegister   := "/oauth/register",
    oauthMetadata   := "/.well-known/oauth-authorization-server",
    mcpMetadata     := "/.well-known/oauth-protected-resource" ]
