/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import MCP
public import Crypto.Compare
public import Todo.ChatTools
public import Todo.ChatTurn

public section

open Std.Async (Async)
open Telemetry (TelemetryT)

namespace Todo.Mcp

/-- Whose list an MCP request reaches, and the credential that reaches it.

One account and one token, both read from the environment, which is what an endpoint has before
there is an authorization server to issue anything. Everything above this line is the shape the
real thing will keep; only where the credential comes from changes. -/
structure Settings where
  token : String
  account : Account

/-- What a deployment's settings came to.

`off` and `misconfigured` both leave the endpoint absent, and they are told apart because only
one of them is a mistake. Silently treating the second as the first is what leaves somebody
looking at an endpoint that answers every question with an empty list. -/
inductive Configuration where
  | off
  | on (settings : Settings)
  | misconfigured (reason : String)

/-- The address is what the person setting this knows; an account id is a string they could only
get by reading it out of the database. An address that no account signs in with is a mistake
rather than a way of switching the endpoint off. -/
def settingsFor (accountFor : String → IO (Option Account)) (token address : Option String) :
    IO Configuration := do
  match token, address with
  | some token, some address =>
    match ← accountFor address with
    | some account => pure (.on { token, account })
    | none => pure (.misconfigured s!"MCP_ACCOUNT is {address}, which no account signs in with")
  | some _, none => pure (.misconfigured "MCP_TOKEN is set but MCP_ACCOUNT is not")
  | none, some _ => pure (.misconfigured "MCP_ACCOUNT is set but MCP_TOKEN is not")
  | none, none => pure .off

/-- A mistake is reported where whoever made it will see it, which for both deployments is the
log. Neither is a reason to refuse to start: the endpoint is not the application. -/
def settingsFromEnv (accountFor : String → IO (Option Account)) : IO (Option Settings) := do
  let env (name : String) : IO (Option String) := do
    pure ((← IO.getEnv name).filter (!·.isEmpty))
  match ← settingsFor accountFor (← env "MCP_TOKEN") (← env "MCP_ACCOUNT") with
  | .on settings => pure (some settings)
  | .off => pure none
  | .misconfigured reason =>
    IO.eprintln s!"{reason}. The MCP endpoint is off."
    pure none

/-- The credential a request presents, if it presents one in the only form MCP allows. -/
def bearer? (header : Option String) : Option String :=
  header.bind fun value =>
    let trimmed := value.trimAscii.toString
    if trimmed.toLower.startsWith "bearer " then some (trimmed.drop 7).trimAscii.toString
    else none

/-- Byte-by-byte rather than `==`, which stops at the first difference and so reports how long a
correct prefix a guess had. -/
def presents (settings : Settings) (credential : String) : Bool :=
  Crypto.bytesEqual settings.token.toUTF8 credential.toUTF8

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
cannot come to disagree about what exists.

`instructions` is the tool guidance alone. The rest of `systemPrompt` describes a panel that an
agent reaching this endpoint is not part of. -/
def server (store : Store) : MCP.Server (TelemetryT Async) Account where
  info := { name := "todomvc", version := "0.1.0" }
  instructions := some toolGuidance
  tools := ChatTools.registry.map (toolDef store)

/-- The catalogue is settled at compile time and is the same for every caller, so it is worth
caching and there is nothing in it to keep from a shared cache. -/
def config : MCP.Config where
  cacheTtlMs := 300000
  cacheScope := .shared

end Todo.Mcp
