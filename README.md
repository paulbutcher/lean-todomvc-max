# TodoMVC

[TodoMVC](https://todomvc.com) in Lean 4, with what a deployed application needs around it:
passwordless sign-in, per-account lists, SQL migrations, OpenTelemetry spans and logs, and an
assistant panel that reads and changes the list through tool calls to a model on Bedrock. The same
code runs as an ordinary server on a laptop and as a Lambda function URL over RDS Postgres.

The UI is HTMX plus a very little JavaScript.

## Why Lean?

- **Markup is typed and formally verified.** A `<div>` inside a `<p>` is a type error, text
  content is escaped on the way in, and `Node.render_wellFormed` proves that what comes out is
  well-formed HTML.
- **Routes are strongly typed.** A handler of the wrong arity or the wrong
  type does not compile, and a link cannot drift from the route that serves it.
- **`hx-*` attributes are record fields.** A misspelt one does not
  compile, and `hx-swap` is a closed enum, so neither does an invalid swap.
- **What the model writes is untrusted input.** A reply is Markdown that reaches the page as HTML.
  lean-markdown is total, never panicking or looping on any input including adversarial input.
  `renderHtmlSafe` is proved to emit well-formed HTML in which no string from the document can
  produce markup or break out of an attribute.
- **The account is in the type.** Every operation on `Store` takes an `Account`, mutations included
  ([Todo/Store.lean](Todo/Store.lean)), and an `Account` is indexed by the tenant it belongs to.
  Reaching another person's row is not a check that can be forgotten, because omitting it is a type
  error.
- **Encodings are proved to round-trip.** What is written to a chat row is what is read
  back from it (`toMsg_ofMsg`), which matters because the conversation is replayed to the model in
  full on every turn. Underneath, leancrypto proves `decode (encode bytes) = some bytes` for hex,
  base64, base64url and Crockford base32, that its modular exponentiation agrees with
  `base ^ exponent % modulus`, and that its early-exit-free comparison is equality.
- **Security properties are theorems.** A page carries its anti-forgery attribute exactly when it
  has a token to put in it (`csrfAttrs_nonempty_iff`): never announcing one it lacks, never dropping
  one it has. A sign-in refusal is proved to speak only about the request and never about who owns
  the address (`onlySpeaksAboutTheRequest`), stated over the whole outcome type, so a case added
  upstream has to be answered here rather than defaulting into a leak.
- **Totality is the default.** Nothing in this application is `partial` and nothing in it can panic,
  and the same holds of every library in the table below: a loop that reads until its input runs out
  carries a bound and a proof that it decreases, rather than an exemption from the termination
  checker. `warningAsError` is on, so an unfinished proof cannot be left behind.

## The stack

Lean 4.33, `Std.Http.Server`, and:

| | |
|---|---|
| [lean-html](https://github.com/paulbutcher/lean-html) · [lean-htmx](https://github.com/paulbutcher/lean-htmx) | typed markup and typed `hx-*` attributes |
| [lean-routing](https://github.com/paulbutcher/lean-routing) | typed router and route table |
| [lean-middleware](https://github.com/paulbutcher/lean-middleware) | sessions, sealed cookie store, anti-forgery, static files, request tracing |
| [lean-authentication](https://github.com/paulbutcher/lean-authentication) | magic links, sessions, rate limiting, bounce handling, consent |
| [leanpostgres](https://github.com/paulbutcher/leanpostgres) · [leanmigrate](https://github.com/paulbutcher/leanmigrate) | `libpq` bindings with a connection pool; migrations as plain SQL files |
| [lean-telemetry](https://github.com/paulbutcher/lean-telemetry) | OpenTelemetry traces and logs |
| [lean-llmclient](https://github.com/paulbutcher/lean-llmclient) · [lean-markdown](https://github.com/paulbutcher/lean-markdown) | provider-agnostic chat with tool calling; GFM for rendering replies |
| [lean-aws](https://github.com/paulbutcher/lean-aws) · [lean-aws-lambda](https://github.com/paulbutcher/lean-aws-lambda) | SigV4 signing; the Lambda runtime interface |
| [lean-json](https://github.com/paulbutcher/lean-json) | JSON (see below) |

## Why lean-json

Everything here reads and writes JSON with `lean-json` rather than with `Lean.Data.Json`.

The deployed binary here is 12 MB; `Lean.Data.Json` is part of the compiler frontend and linking that frontend would increase the binary size by ~125MB. This increases cold start times from the current ~2 seconds ~15 seconds.

`lean-json` provides some stronger guarantees than `Lean.Data.Json`: nothing in it is `partial`, nothing can panic, it is proved correct against the grammar of RFC 8259, and no operation walks a value on the C stack, so a deeply nested document is a bounded error rather than a crash. Codecs, paths, `deriving ToJson, FromJson` and `json%` literals are all there; see its [README](https://github.com/paulbutcher/lean-json#readme).

## Building and running

Needs a Postgres, `libpq` and `libcurl` development packages, and the toolchain in
[lean-toolchain](lean-toolchain). [.devcontainer](.devcontainer/) has all of it.

```
lake build
lake exe TodoMVC        # http://localhost:8080
lake test               # uses the same database
```

`libpq` reads the connection from the usual `PG*` variables. Migrations run at startup, so a fresh
database needs nothing first; `lake exe migrate` applies and rolls them back by hand. Sign-in mail is
printed to the terminal rather than sent, so following a magic link needs no mail server, and spans
are printed there too in a readable form.

For the assistant panel, anything that puts credentials in the environment will do:

```
eval "$(aws configure export-credentials --profile <profile> --format env)"
export AWS_REGION=<region>
export BEDROCK_MODEL=<model-or-inference-profile-id>
```

## Deploying to your own account

[template.yaml](template.yaml) defines a [SAM](https://aws.amazon.com/serverless/sam/) deployment: a VPC with no egress, an RDS Postgres, the function behind a public function URL, interface endpoints for SES and Bedrock, secrets, a log group, a dashboard and its saved queries.

You need AWS credentials, a Docker that can build `linux/arm64`, and an SES identity for the address
you will send from. Give its domain SPF, DKIM, DMARC and an MX record, and while the account is in
the SES sandbox, verify the recipients too.

```
sam build
sam deploy --guided --stack-name todomvc
```

Answer yes to creating a managed ECR repository. `MailFrom` is the only parameter without a default.

A sign-in link has to name an origin, and the function URL is not knowable until the function exists,
so deploy a second time with `BaseUrl` set to what the first deploy printed (either run `sam deploy --guided` a second time or edit the created `samconfig.toml`).

For the assistant, set `BedrockModel` to an id enabled in that region. Most current models are
reachable only through a cross-region inference profile, which `aws bedrock list-inference-profiles`
lists. A Marketplace-served model enables itself on first invocation, and that invocation must come
from a principal holding `aws-marketplace:Subscribe`, so prime it once from an administrative
identity rather than widening the function's role:

```
aws bedrock-runtime converse --region <region> --model-id "<id>" \
  --messages '[{"role":"user","content":[{"text":"hello"}]}]'
```

## Telemetry

The function has no egress, so spans and log records leave as one flat JSON object per line on
stdout, which the runtime forwards to CloudWatch Logs. Flat rather than OTLP so that any field on any
row can be grouped by at query time, at any cardinality: the log group is queried like a trace store
rather than read like a transcript.

`lake exe logs` renders those rows back into the form the local server prints directly:

```
sam logs --stack-name todomvc --tail | lake exe logs
```

The `Dashboard` stack output is a console URL for the dashboard the template creates: platform
metrics, server latency, p99 by route, slowest requests, and errors. Beside it, under Logs Insights,
the template saves the steps of an analysis loop as query definitions, from slowest routes down to a
single trace read end to end.

## License

Copyright (c) 2026 Paul Butcher. Apache 2.0; see [LICENSE](LICENSE).
