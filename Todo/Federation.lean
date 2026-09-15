/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import Authentication
public import Authentication.Instances
public import AuthenticationFetch
public import AuthenticationOidc
public import Leancrypto.Codec.Base64Url

public section

open Authentication

namespace Todo.Federation

/-- Where configuration is read from. A parameter rather than `IO.getEnv` throughout so that what
this does with a half-configured provider can be tested, which is the whole of its behaviour. -/
abbrev Lookup := String → IO (Option String)

/-- A provider this deployment offers, and what it takes to prove this client to it.

Held apart from `Authentication.ProviderConfig` only long enough to read it: the environment names
a provider by its client id, and the rest of the entry is meaningless without one. -/
structure Reader where
  id : ProviderId
  issuer : String
  /-- The variable holding the client id. Everything else this provider needs is read only if it
  is set, so one variable turns a provider on. -/
  clientIdVar : String
  credentials : Lookup → IO ProviderCredentials
  formPost : Bool := false
  endpoints : ProviderEndpoints := .discovered
  scopes : List String := ["openid", "email"]

/-- What the deployment configured, once. `providers` is never empty: nothing is configured is
`none`, which is a different thing and kept a different thing. -/
structure Settings where
  sealing : Oidc.SealingRing
  providers : List ProviderConfig

private def env (get : Lookup) (name : String) : IO (Option String) := do
  match ← get name with
  -- A stack parameter left at its default arrives as an empty string rather than being left out,
  -- so the two have to mean the same thing or every default would configure a provider.
  | some value => pure (if value.isEmpty then none else some value)
  | none => pure none

private def required (get : Lookup) (name : String) : IO String := do
  let some value ← env get name
    | throw (IO.userError s!"{name} is not set, and the provider it belongs to is configured")
  pure value

/-- Refuses rather than dropping the provider.

A secret that will not parse is a deployment that meant to offer this provider and got it wrong.
Reading that as "this provider was not asked for" is the mistake that deploys cleanly, serves a
sign-in page with a button missing, and tells nobody. -/
private def storedSecret (get : Lookup) (name : String) : IO StoredSecret := do
  let raw ← required get name
  let some secret := StoredSecret.parse raw
    | throw (IO.userError s!"{name} is not a secret this can read; seal it with `lake exe auth-seal`")
  pure secret

/-- The three this application offers.

GitHub publishes no discovery document, so its endpoints are configuration rather than something
to read, and the two calls its profile takes are the last two. Apple posts its answer back rather
than redirecting, which is what `formPost` says, and its secret is minted per request from a key
rather than held. -/
def readers : List Reader :=
  [ { id := ⟨"google"⟩
      issuer := "https://accounts.google.com"
      clientIdVar := "GOOGLE_CLIENT_ID"
      credentials := fun get => do pure (.clientSecret (← storedSecret get "GOOGLE_CLIENT_SECRET")) }
  , { id := ⟨"apple"⟩
      issuer := "https://appleid.apple.com"
      clientIdVar := "APPLE_CLIENT_ID"
      credentials := fun get => do
        pure (.signingKey (← required get "APPLE_TEAM_ID") (← required get "APPLE_KEY_ID")
          (← storedSecret get "APPLE_SIGNING_KEY"))
      formPost := true
      scopes := ["openid", "email", "name"] }
  , { id := ⟨"github"⟩
      issuer := "https://github.com"
      clientIdVar := "GITHUB_CLIENT_ID"
      credentials := fun get => do pure (.clientSecret (← storedSecret get "GITHUB_CLIENT_SECRET"))
      endpoints := .configured
        "https://github.com/login/oauth/authorize"
        "https://github.com/login/oauth/access_token"
        "https://api.github.com/user"
        "https://api.github.com/user/emails"
      scopes := ["read:user", "user:email"] } ]

private def read (get : Lookup) (reader : Reader) : IO (Option ProviderConfig) := do
  let some clientId ← env get reader.clientIdVar | pure none
  pure (some
    { id := reader.id, issuer := reader.issuer, clientId
      credentials := ← reader.credentials get
      formPost := reader.formPost
      endpoints := reader.endpoints
      scopes := reader.scopes })

/-- The key every sealed secret is opened under, which is the one thing here that must not live
beside the database it protects. -/
private def sealingRing (get : Lookup) : IO Oidc.SealingRing := do
  let encoded ← required get "AUTH_SEALING_KEY"
  let some secret := Leancrypto.Codec.Base64Url.decodeString encoded
    | throw (IO.userError "AUTH_SEALING_KEY is not base64url; mint one with `lake exe auth-seal key`")
  if secret.size != 32 then
    throw (IO.userError s!"AUTH_SEALING_KEY decodes to {secret.size} bytes, and 32 are wanted")
  pure { current := { keyId := ⟨← required get "AUTH_SEALING_KEY_ID"⟩, secret } }

/-- `none` where no provider is named, which is the deployment that offers the magic link and
nothing else. Naming one and getting the rest of it wrong throws. -/
def fromLookup (get : Lookup) : IO (Option Settings) := do
  let providers ← readers.filterMapM (read get)
  if providers.isEmpty then pure none
  else pure (some { sealing := ← sealingRing get, providers })

def fromEnv : IO (Option Settings) := fromLookup (fun name => IO.getEnv name)

/-- Built once, because `metadata` and `keys` each hold a cache of what a provider publishes.
Per request they would be empty every time and every sign-in would be a fetch of the discovery
document and the key set before anything else happened. -/
def ports (settings : Settings) : IO (Oidc.SignInPorts IO) := do
  let http := Fetch.curlHttp
  let resolved := Oidc.clientSecrets (Oidc.secrets settings.sealing)
  let tokens := Oidc.tokenEndpoint http
  pure
    { metadata := ← Oidc.metadata http
      identities := Oidc.identities http tokens resolved (← Oidc.keys http) }

/-- What a provider is called where somebody has to recognise it. The id is what a URL and a
stored credential carry, and it is lowercase because those are; this is the other thing. -/
def label (id : ProviderId) : String :=
  match id.value with
  | "google" => "Google"
  | "apple" => "Apple"
  | "github" => "GitHub"
  | other => other

end Todo.Federation
