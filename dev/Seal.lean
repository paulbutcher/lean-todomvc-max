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
      "  seal key                          a fresh sealing key, as hex",
      "  seal <provider> <field> < file    the sealed secret, as a line of configuration",
      "  seal check <provider> <field>     whether a sealed value opens, read from stdin",
      "",
      "fields: client-secret, signing-key (Apple's .p8)",
      "reads AUTH_SEALING_KEY and AUTH_SEALING_KEY_ID" ]

/-- Says whether a configured value can be opened by the key this is holding, and never what it
opens to. Which of the failures it was is the whole point: a deployment cannot tell a secret
sealed under another key from one sealed for another provider, because the page a failed sign-in
renders says nothing about either.

Safe to run against production configuration. The plaintext is not printed, and nothing here
reaches the deployment: a sealed value and the key that opens it is all it reads. -/
private def check (provider : String) (field : SecretField) : IO UInt32 := do
  let raw := (← (← IO.getStdin).readToEnd).trimAscii.toString
  let some stored := StoredSecret.parse raw
    | IO.println "not a sealed secret: this is not a value `seal` produced"
      pure 1
  match stored with
  | .external reference =>
    IO.println s!"an external reference ({reference}), which this deployment cannot resolve"
    pure 1
  | .sealed value =>
    let ring : Oidc.SealingRing := { current := ← sealingKey }
    let ref : SecretRef := { tenant := Todo.tenant, provider := ⟨provider⟩, field }
    match ← Oidc.openSecret ring ref value with
    | .ok opened =>
      IO.println s!"opens, {opened.size} bytes, under key {value.keyId.value}"
      pure 0
    | .error (.unknownKey keyId) =>
      IO.println s!"sealed under key {keyId.value}, and AUTH_SEALING_KEY_ID is {ring.current.keyId.value}"
      pure 1
    | .error .keyUnusable =>
      IO.println "AUTH_SEALING_KEY is not 32 bytes"
      pure 1
    | .error _ =>
      IO.println s!"will not open: either AUTH_SEALING_KEY is not the key it was sealed under, \
        or it was sealed for something other than {provider}/{field.name}"
      pure 1

/-- Nothing here writes anywhere. What it prints is what a deployment sets, which keeps the one
copy of a provider's secret in the hands of whoever ran this. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | ["check", provider, rawField] =>
    let some field := field? rawField
      | throw (IO.userError s!"{rawField} is not a field this knows; {usage}")
    check provider field
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
