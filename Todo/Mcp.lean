/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import MCP
public import Todo.Authorization
public import Todo.ChatTools
public import Todo.ChatTurn

@[expose] public section

open Std.Async (Async)
open Telemetry (TelemetryT)

namespace Todo.Mcp

/-! ## What a token lets an agent do

A tool that changes the list needs the scope that says so, and one that only reads it needs the
other. Nothing else distinguishes them, which is why this is a function of `mutates` rather than
a table naming every tool: a tool added to the registry is covered by whichever answer it gives.
-/

def scopeFor (entry : ChatTools.Entry) : Authentication.OAuth.Scope :=
  if entry.mutates then Authorization.write else Authorization.read

/-- The tools a token may use.

Filtering the catalogue rather than refusing the call is what makes a read-only grant legible to
the agent holding it: it is offered what it can do, instead of discovering the boundary by being
turned away from a tool it was told existed. -/
def permitted (held : List Authentication.OAuth.Scope) : Array ChatTools.Entry :=
  ChatTools.registry.filter fun entry => held.contains (scopeFor entry)

/-! ## The server -/

/-- `mutates` is what the protocol calls `readOnlyHint`, which is the same question asked by the
side that consumes the answer. Nothing states `destructiveHint`: it defaults to true for a tool
that is not read-only, and that is the right reading of every tool here that changes anything,
since each of them can remove a todo. -/
def toolDef (store : Store) (entry : ChatTools.Entry) :
    MCP.ToolDef (TelemetryT Async) Account where
  tool :=
    { name := entry.tool.name
      description := some entry.tool.description
      inputSchema := entry.tool.schema
      annotations := { readOnlyHint := some !entry.mutates } }
  run account input := do
    match ← entry.run store account input with
    | .ok text => pure (MCP.ToolResult.text text)
    | .error message => pure (MCP.ToolResult.failure message)

/-- The same tools the panel's own model is offered, from the same registry, so that the two
cannot come to disagree about what exists, narrowed to what the presented token was granted.

`instructions` is the tool guidance alone. The rest of `systemPrompt` describes a panel that an
agent reaching this endpoint is not part of. -/
def server (store : Store) (held : List Authentication.OAuth.Scope) :
    MCP.Server (TelemetryT Async) Account where
  info := { name := "todomvc", version := "0.1.0" }
  instructions := some toolGuidance
  tools := (permitted held).map (toolDef store)

/-- The catalogue is settled at compile time, but which of it a caller sees is not: a read-only
token and a full one are offered different lists. `.caller` is what keeps a shared cache from
serving one the other's answer. -/
def config : MCP.Config where
  cacheTtlMs := 300000
  cacheScope := .caller

end Todo.Mcp
