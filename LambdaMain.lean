/-
Copyright (c) 2026 Paul Butcher. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

module

public import AwsLambdaHttp
public import AuthenticationSes
public import Middleware
public import MiddlewareCookieStore
public import Postgres
public import Telemetry.Sdk
public import Todo

public section

open Std Async
open Telemetry

/-- The key has to outlive any one execution environment. Letting `CookieStore` mint its own
would give each concurrently running instance a different one, so a session sealed by whichever
instance served the page would be unreadable by whichever instance served the next request, and
`antiForgery` would reject every mutation. -/
def sessionStore : IO Middleware.CookieStore := do
  let some encoded ← IO.getEnv "SESSION_KEY"
    | throw (IO.userError "SESSION_KEY is not set")
  let some key := AwsLambda.ofHex? encoded
    | throw (IO.userError "SESSION_KEY is not an even-length run of hex digits")
  if key.size != 32 then
    throw (IO.userError s!"SESSION_KEY decodes to {key.size} bytes, but AES-256 needs 32")
  Middleware.CookieStore.new { key := some key }

/-- The pepper every credential the authentication library stores is digested under. It has to
outlive any one execution environment for the same reason `SESSION_KEY` does, and more: a
different one per instance would make every session and every link in flight unreadable by
whichever instance served the next request.

A rotation needs the old key kept alongside the new one for the lifetime of the longest session,
which `PepperRing.retired` is for. Nothing here reads a second one yet, so a rotation today signs
everyone out. -/
def pepper : IO Authentication.Pepper := do
  let some encoded ← IO.getEnv "AUTH_PEPPER"
    | throw (IO.userError "AUTH_PEPPER is not set")
  let some secret := AwsLambda.ofHex? encoded
    | throw (IO.userError "AUTH_PEPPER is not an even-length run of hex digits")
  if secret.size != 32 then
    throw (IO.userError s!"AUTH_PEPPER decodes to {secret.size} bytes, and 32 are wanted")
  let some keyId ← IO.getEnv "AUTH_PEPPER_KEY_ID"
    | throw (IO.userError "AUTH_PEPPER_KEY_ID is not set")
  pure { keyId := ⟨keyId⟩, secret }

/-- The execution role's credentials, as the runtime publishes them.

They expire. The runtime replaces these variables underneath a warm environment when it renews
them, so this is read per send rather than once at startup; see `Todo.Auth.refreshing`. Reading it
once is the mistake that works all the way through a deployment and then fails hours later. -/
def awsCredentials : IO Aws.Sigv4.Credentials := do
  let some accessKeyId ← IO.getEnv "AWS_ACCESS_KEY_ID"
    | throw (IO.userError "AWS_ACCESS_KEY_ID is not set")
  let some secretAccessKey ← IO.getEnv "AWS_SECRET_ACCESS_KEY"
    | throw (IO.userError "AWS_SECRET_ACCESS_KEY is not set")
  -- Absent only for long-lived credentials, which a role never has.
  let sessionToken ← IO.getEnv "AWS_SESSION_TOKEN"
  pure { accessKeyId, secretAccessKey, sessionToken }

/-- Everything the mail needs that this process cannot discover for itself. The base URL is the
origin the magic link points back at, which is the function's own and so is settled when it is
deployed rather than here.

SES needs no secret of its own: the request is signed with the role the function already runs as,
which is why nothing here reads a provider token. -/
def authSettings : IO Todo.Auth.Settings := do
  let some raw ← IO.getEnv "BASE_URL"
    | throw (IO.userError "BASE_URL is not set")
  -- `ofString` trims the trailing slash a function URL is published with, so what is checked
  -- below is what a link will actually be built from: an origin of nothing but slashes is as
  -- empty as an empty one, and neither can name anywhere a browser could come back to.
  let baseUrl := Authentication.BaseUrl.ofString raw
  if baseUrl.origin.isEmpty then
    throw (IO.userError "BASE_URL names no origin, so a sign-in link would point nowhere")
  let some sender ← IO.getEnv "MAIL_FROM"
    | throw (IO.userError "MAIL_FROM is not set")
  let .ok address := Authentication.EmailAddress.parse sender
    | throw (IO.userError s!"MAIL_FROM is {sender}, which is not an email address")
  -- Set by the runtime, and not settable in the function's own configuration.
  let some region ← IO.getEnv "AWS_REGION"
    | throw (IO.userError "AWS_REGION is not set")
  pure
    { pepper := ← pepper
      baseUrl
      sender := { address, displayName := "todos" }
      transport := Todo.Auth.refreshing awsCredentials fun credentials =>
        Authentication.Ses.transport { region, credentials } }

/-- The panel, signed with the same execution role everything else here is.

`awsCredentials` is passed rather than called, for the reason it documents: the runtime replaces
those variables underneath a warm environment, and a turn hours after the cold start has to sign
with what is there then. `AWS_REGION` is set by the runtime and is the region the function is
deployed in, which is where the model has to be enabled.

Nothing here fails on a region it cannot find, because the failure belongs in the panel rather
than in the init that would take the todo list down with it. -/
def assistant (pool : Postgres.Pool) : IO Todo.Assistant := do
  let region := (← IO.getEnv "AWS_REGION").getD "us-east-1"
  pure
    { provider := Todo.bedrockProvider awsCredentials region
      chat := Todo.Db.chatStore pool
      turns := ← Todo.Turns.new }

/-- Only timeouts: everything identifying the database comes from the `PG*` variables the
deployment sets, and libpq has no environment variable for either of these.

`tcp_user_timeout` is what makes a broken connection discoverable here at all. The execution
environment is frozen between invocations, so a connection can be silently dropped by the network
in front of it with no close ever delivered; without a bound the operating system retransmits for
several minutes, far longer than the function's own timeout. Keepalives are the usual companion to
this and are deliberately absent: nothing can be sent while the environment is frozen, which is
precisely the period the flow goes away in.

Both are well inside the function timeout even if a borrow has to wait out one and then open a
fresh connection. -/
def conninfo : String := "connect_timeout=5 tcp_user_timeout=5000"

/-- Lambda runs one invocation at a time per execution environment, and the runtime serves them
sequentially, so one connection is all that can ever be in use. Capacity here is multiplied by the
function's reserved concurrency to give the load the database sees, which is the reason not to
round it up for comfort. -/
def poolSize : Nat := 1

/-- `faas.instance` identifies the execution environment, which only the process itself can
report: a log stream belongs to one environment and its name arrives in that environment. Anything
else the resource wants about the function is settled when the function is deployed and is set
there, through `OTEL_RESOURCE_ATTRIBUTES`. -/
def instanceAttrs : IO Attrs := do
  let some stream ← IO.getEnv "AWS_LAMBDA_LOG_STREAM_NAME" | return []
  return [("faas.instance", .str stream)]

/-- Anything raised here happens before the first invocation, and `AwsLambda.serve` reports it to
the runtime API's init endpoint rather than just logging it, so the environment is torn down
immediately instead of accepting an invocation it has no working database connection to serve.
Installing telemetry first puts a misconfigured exporter, which the SDK raises on rather than
starting quietly without, on that same footing.

Migrating is the one thing here worth a span of its own: it runs on every cold start, and the
environment is frozen the moment the first invocation is answered, so it is otherwise invisible.

There is no matching `Sdk.shutdown`. Nothing tells the function its environment is about to go,
and nothing is buffered for one to flush. -/
def main : IO Unit := AwsLambda.serve do
  Sdk.installFromEnv (extraAttrs := ← instanceAttrs)
  let pool ← Postgres.Pool.create conninfo poolSize
  runTelemetry (spanning "migrate" (liftM (Postgres.Pool.withConnAsync pool Todo.migrate)))
  let sessions ← sessionStore
  let site := Todo.Auth.site pool (← authSettings)
  let assistant ← assistant pool
  -- A function URL is reachable over https only, so TLS termination is a given here.
  pure (AwsLambda.Http.handler
    (Todo.server site.identity site.handler (Todo.Db.store pool) assistant sessions
      (https := true)))
