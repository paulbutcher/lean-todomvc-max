# OpenTelemetry integration plan

Tracking document for integrating [lean-telemetry](https://github.com/paulbutcher/lean-telemetry)
(v0.1.1) into this application. Delete once the work has landed and settled.

## The constraint everything follows from

`MonadTelemetry` carries the current span in a `ReaderT (Option SpanContext)` layer. Our handler
monad is `ContextAsync = ReaderT CancellationContext Async`, and that type is pinned by
`Std.Http.Server.StatelessHandler`. We cannot add a `TelemetryT` layer to the handler type without
forking Std, so there is no ambient parent span.

lean-telemetry anticipates this: `SpanContext` derives `TypeName` so it can live in a typed
extension map, and `Routing.MatchedRoute` already documents `segs` as the low-cardinality template
`http.route` wants. So the shape is: a middleware opens the server span and publishes its
`SpanContext` into the request's `extensions`; anything wanting a child re-enters `TelemetryT`
seeded from there.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Span propagation | `SpanContext` in request `extensions` | The only channel available; the handler monad is fixed by Std. |
| `Store` monad | `TelemetryT Async` | Confines the seam to `Todo.App`; the alternative was an extra parent argument on every operation. |
| DB instrumentation | At our `Store` boundary | Cheap and ours. Pool-borrow visibility would need leanpostgres to go `MonadTelemetry`-polymorphic. |
| Server-span middleware | Implemented here, extracted later | Generic enough for lean-middleware, but not worth moving before we have seen the traces. |
| Route template | `routeName` callback parameter | Keeps a middleware/routing dependency edge out of the eventual extraction. |
| Stack position | Inside `catchAll` | The span sees the exception and keeps its message; `catchAll` stays telemetry-unaware. |
| Lambda export | File exporter plus ADOT collector extension layer | The pattern the library is written for. Direct OTLP is not implemented and stdout needs a CloudWatch pipeline. |
| Local export | Console, pretty | Nothing to configure; readable in the terminal. |

### Consequences of the `catchAll` placement

The outermost header middlewares (`forwardedScheme`, `forwardedRemoteAddr`, `hsts`,
`xFrameOptions`, `xContentTypeOptions`) and `catchAll` itself go untimed. None does I/O, so the
loss is negligible, and a failure originating in one of them would produce no span at all.

On the error path this placement is the better one, not a compromise: an exception passes through
`Telemetry.span`'s own handler first, so the span carries status `error` and the exception's
message before `catchAll` turns it into a `500`. The cost is that such a span has no
`http.response.status_code`, since no response ever came back to it. A query for failures has to
go by span status rather than by code.

## Work items

- [x] Require `telemetry` v0.1.1 in `lakefile.toml`.
- [x] `Todo.Store`: operations become `TelemetryT Async`.
- [x] `Todo.Db`: a `client` span per store operation, covering borrow and statements together,
      carrying `db.system.name` and `db.operation.name`.
- [x] `Todo.Tracing`: `serverSpan` middleware and the `parentSpan` accessor.
- [x] `Todo.App`: `serverSpan` into the stack immediately inside `catchAll`, passing
      `Routing.matchedRoute?` rendered through `Routing.renderPattern`; handlers seed store calls
      from `parentSpan req`.
- [x] `Main`: `Sdk.installFromEnv` at startup, `Sdk.shutdown` on the way out.
- [x] `LambdaMain`: `Sdk.installFromEnv` before the pool is opened, and a span around
      `Todo.migrate`, which runs on every cold start and is currently invisible.
- [x] Instructions for a lean-telemetry agent covering the testing change:
      `TELEMETRY_TESTING_BRIEF.md`. Landed in telemetry v0.2.0 as `Telemetry.Testing`.
- [x] Instructions for a lean-telemetry agent covering the OTLP/HTTP exporter:
      `TELEMETRY_OTLP_BRIEF.md`. Landed in telemetry v0.2.0, along with `installFromEnv`'s
      `extraAttrs`.
- [x] `TodoTests.Tracing`: the four claims from the testing brief, using `Testing.capture`.
- [x] `LambdaMain`: `faas.instance` through `extraAttrs`, which nothing outside the process knows.
- [x] `collector.yaml`: OTLP in on loopback, `decouple`, both signals out over OTLP/HTTP.
- [x] `Dockerfile`: collector unpacked into `/opt/extensions`, plus the two things leancurl needs.
- [x] `template.yaml`: the `OTEL_*` variables, the collector config URI, and parameters for the
      backend endpoint and credential.

## The deployed export path has to change

Two facts found while trying to write the template, each of which kills part of the original
plan.

**The collector cannot be a layer.** The function is `PackageType: Image`, and Lambda does not
attach layers to container-image functions. Not fatal on its own: Lambda still runs external
extensions from `/opt/extensions`, so the collector can be copied into the image at build time and
registers through the Extensions API as normal.

**The Lambda collector has no file receiver.** This is the fatal one.
`opentelemetry-lambda/collector/lambdacomponents/default.go` builds a deliberately small component
set, and its receivers are exactly two: `otlp` and `telemetryapi`. There is no `otlpjsonfile`, no
`filelog`, nothing that reads from disk. So a collector in the image cannot pick up what the file
exporter writes, whatever directory we point it at.

Adding one means forking: components are selected by Go build tag from files under
`lambdacomponents/`, so an `otlpjsonfile` receiver needs a new file in that tree, a Go toolchain in
the image build, and a patch carried against upstream indefinitely.

The same list also has no `resourcedetection` processor, so the plan for Lambda resource
attributes below does not work either. `resource` is available and can set static attributes, and
`coldstart` is available and is interesting in its own right.

### How it was resolved

telemetry v0.2.0 added an OTLP/HTTP exporter, so the function now speaks OTLP to a collector on
loopback and the collector is unpacked into `/opt/extensions` at image build time. The file
exporter is unused in the deployment.

Two consequences of that exporter which are now part of the deployment rather than the plan:

- It reaches libcurl through `leancurl`, whose shim is a shared library the binary loads by name.
  The image has to carry `libleancurl_shim.so` and the full `libcurl`, or the function does not
  start at all. This was confirmed the hard way: the binary refuses to load outside `lake env`
  without it.
- Export failure never reaches the application. Verified locally by running with
  `OTEL_TRACES_EXPORTER=otlp` and nothing listening: requests were served normally, and the whole
  run produced one line of stderr rather than one per span. Worth knowing that a *refused*
  connection fails instantly, which is the loopback case; a collector that black-holed packets
  would cost `OTEL_EXPORTER_OTLP_TIMEOUT` per export instead.

### Where that left us

The collector accepts OTLP and nothing else useful to us. So the in-image collector, which is
otherwise a good fit, needs the function to speak OTLP to it.

That is a much smaller ask than "a direct OTLP/HTTP exporter" sounded like when it was first
weighed, because the target is `127.0.0.1:4318` in the same execution environment. No TLS, no
authentication, no retry policy, no endpoint configuration worth the name: the collector does all
of that on the way out, which is the division of labour lean-telemetry's README already describes.
`Std.Http` ships a server but no client, so it would be hand-rolled HTTP/1.1 over TCP; lean-aws-lambda
already does exactly this against the runtime API, so there is a working precedent in a sibling
project.

The alternative that needs nothing from anyone is OTLP/JSON on stdout, forwarded by the runtime to
CloudWatch Logs and taken onward by a subscription filter into a collector running elsewhere. It
pays CloudWatch ingestion per span and gives stdout over to the machine, so the readable format is
gone from that stream, but it works today and needs no image change.

## Testing

There is nothing meaningful to assert about the instrumentation until we can observe what it
emits, and lean-telemetry's in-memory exporter lives in its `test/` tree rather than in the
shipped SDK. The claims worth testing, all of which need it:

- The server span is named for the route *template*, not the concrete path with the id in it.
  This is the whole point of the `rename` and would regress silently.
- A response the router did not match carries no `http.route` rather than a guessed one.
- An exception from a handler leaves the span with status `error` and the message, and is
  re-raised rather than swallowed.
- A store operation's span is a child of the request's span, which is what the extensions
  round-trip exists to achieve.

Until then the existing handler tests stand as a regression check that the instrumentation changes
no behaviour, which they do by construction: with no SDK installed `span` hands out an inert span
and `parentSpan` returns `none`.

## Configuration

Local development needs nothing set: the console exporter in pretty format is the default.

Deployed:

| Variable | Value | Note |
|---|---|---|
| `OTEL_SERVICE_NAME` | `todomvc` | |
| `OTEL_TRACES_EXPORTER` | `file` | Console output would go to CloudWatch and be paid for twice. |
| `OTEL_LOGS_EXPORTER` | `file` | |
| `OTEL_EXPORTER_FILE_DIRECTORY` | `/tmp/telemetry` | Everything outside `/tmp` is read-only. |
| `OTEL_EXPORTER_FILE_MAX_SIZE` | to settle | `/tmp` is 512MB and persists across invocations in a warm environment, so this and the segment count are live settings rather than defaults. |
| `OTEL_EXPORTER_FILE_MAX_SEGMENTS` | to settle | |

The collector reads the segments with the `otlpjsonfile` receiver and forwards over OTLP.

## Resource attributes

`Resource.detected` reads `HOSTNAME`, which Lambda does not set, so `host.name` will be `unknown`.
The FaaS attributes worth having are `cloud.provider`, `cloud.platform`, `cloud.region`,
`faas.name`, `faas.version`, `faas.max_memory` and `faas.instance`, all derivable from the
`AWS_*` variables Lambda sets.

`installFromEnv` takes no extra attributes and `Sdk.build` is private, so the application cannot
inject them while still letting the environment choose exporters.

The collector was going to supply them, but its Lambda build has no `resourcedetection` processor.
What is left:

- `OTEL_RESOURCE_ATTRIBUTES` in `template.yaml`, which covers function name, version and region,
  all known at deploy time, but not `faas.instance`, which is per execution environment.
- The collector's `resource` processor, which is in the build and can set static attributes. Same
  limitation, and it duplicates what the environment variable already does.
- An `extraAttrs` parameter on `installFromEnv`, which would be a small lean-telemetry change and
  the only option that reaches `faas.instance`.

## Deferred

- **Extracting `serverSpan` into lean-middleware.** Once the traces have told us what the span
  should actually carry.
- **`catchAll` emitting an error log record.** It currently swallows the exception. Reasonable
  while our span sits inside it and reports the exception itself; revisit if the span moves out.
- **W3C `traceparent` propagation.** Not implemented in lean-telemetry, so our traces are always
  roots and will not join anything upstream. Related: `AwsLambda.Api` discards the runtime API's
  `Lambda-Runtime-Trace-Id`.
- **Sampling.** Not implemented. The server span currently covers static asset requests served by
  the `file` middleware as well as real routes, which is one synchronous export per asset. Watch
  the volume before deciding whether to filter.
- **Pool-borrow timing.** Needs `Postgres.Pool` to hand out a borrow as a value rather than only
  as a bracket, or leanpostgres instrumentation of its own.
- **Cold-start cost of the collector layer.** Measure once it is deployed.

## Open questions

- Which backend is this going to, and what does it call its auth header? `collector.yaml` sends
  `authorization`, which suits most OTLP-native endpoints; Honeycomb wants `x-honeycomb-team`.
  The key has to change, not just the value.
- Nothing has been deployed or run in Lambda yet. The image builds are unexercised, the collector
  has never started, and `decouple` has never been asked to hold an invocation open.
- What should `http.route` look like? `Routing.renderPattern` gives `/todos/:id:Nat`, which
  carries the capture's type. Correct and low-cardinality, but not the conventional spelling, and
  it is what the span is named by, so it is the first thing anyone reading a trace will see. A
  template spelling without the type would have to come from routing.

## Noticed while instrumenting

`Todo.render` issues two `SELECT`s: the filtered list and, for the counter, the full one. On the
unfiltered page those are the same query run twice. Nothing to do with telemetry, but the traces
put it in plain sight, so it is recorded here rather than lost.

## Cardinality and content

Method, route template, path, status code and client address are all safe. Todo ids are fine. Todo
**titles** are user content and must not go on spans.
