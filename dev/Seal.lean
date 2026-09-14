/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Authentication.Instances
public import AuthenticationOidc
public import Leancrypto.Codec.Hex
public import Todo.Tenant

public section

open Authentication

/-- The secret is read from standard input rather than taken as an argument, because an argument
is in the process list while it runs and in a shell history afterwards.

Binary rather than text: Apple's is the bytes of a `.p8` file, and reading it as a string would
put this at the mercy of whatever the file happens to encode. -/
private def plaintext : IO ByteArray := do
  (← IO.getStdin).readBinToEnd

private def sealingKey : IO Oidc.SealingKey := do
  let some encoded ← IO.getEnv "AUTH_SEALING_KEY"
    | throw (IO.userError "AUTH_SEALING_KEY is not set; `seal key` makes one")
  let some secret := Leancrypto.Codec.Hex.decodeString encoded
    | throw (IO.userError "AUTH_SEALING_KEY is not an even-length run of hex digits")
  let some keyId ← IO.getEnv "AUTH_SEALING_KEY_ID"
    | throw (IO.userError "AUTH_SEALING_KEY_ID is not set")
  pure { keyId := ⟨keyId⟩, secret }

private def field? : String → Option SecretField
  | "client-secret" => some .clientSecret
  | "signing-key" => some .signingKey
  | _ => none

private def usage : String :=
  String.intercalate "\n"
    [ "usage:",
      "  seal key                        a fresh sealing key, as hex",
      "  seal <provider> <field> < file  the sealed secret, as a line of configuration",
      "",
      "fields: client-secret, signing-key (Apple's .p8)",
      "reads AUTH_SEALING_KEY and AUTH_SEALING_KEY_ID" ]

/-- Nothing here writes anywhere. What it prints is what a deployment sets, which keeps the one
copy of a provider's secret in the hands of whoever ran this. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | ["key"] =>
    match ← RandomBytes.draw 32 with
    | .error detail => throw (IO.userError s!"no random bytes: {detail}")
    | .ok secret =>
      IO.println (Leancrypto.Codec.Hex.encodeString secret)
      pure 0
  | [provider, rawField] =>
    let some field := field? rawField
      | throw (IO.userError s!"{rawField} is not a field this knows; {usage}")
    let ref : SecretRef := { tenant := Todo.tenant, provider := ⟨provider⟩, field }
    match ← Oidc.sealSecret (← sealingKey) ref (← plaintext) with
    | .error _ =>
      -- The one failure a caller can act on is a key of the wrong length; the rest describe the
      -- machine rather than the input.
      throw (IO.userError "could not seal: AUTH_SEALING_KEY must decode to 32 bytes")
    | .ok sealed =>
      IO.println (StoredSecret.sealed sealed).render
      pure 0
  | _ =>
    IO.println usage
    pure 1
