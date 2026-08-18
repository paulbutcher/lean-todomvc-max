# OpenTelemetry integration plan

Tracking document for integrating [lean-telemetry](https://github.com/paulbutcher/lean-telemetry)
v0.2.0 into this application. Delete once the work has landed and settled.

Instrumentation is complete and exercised locally. The deployment is prepared but has never been
deployed; see "Not yet true" at the end.

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
| Server-span middleware | `middleware-tracing`, upstream | Extracted once the traces showed what it should carry. A package beside `cookiestore` rather than `middleware` itself, so that lean-telemetry and its `leancurl` requirement stay out of every application using any middleware at all. |
| Route template | `Routing.matchedPattern?` | Passed to `serverSpan` as its `routeName` callback, which is what keeps a routing dependency out of `middleware-tracing`. Renders `/todos/:id`, not `renderPattern`'s `/todos/:id:Nat`: an endpoint's identity must not move when a capture's kind changes, since no client can observe that but every dashboard keyed on the route would break. |
| Stack position | Inside `catchAll` | The span sees the exception and keeps its message; `catchAll` stays telemetry-unaware. |
| Local export | Console, pretty | Nothing to configure; readable in the terminal. |
| Deployed export | Console, `otlp_json`, to CloudWatch Logs | The only way out of a VPC with no egress, and it needs no collector. See below. |

### Consequences of the `catchAll` placement

The outermost header middlewares (`forwardedScheme`, `forwardedRemoteAddr`, `hsts`,
`xFrameOptions`, `xContentTypeOptions`) and `catchAll` itself go untimed. None does I/O, so the
loss is negligible, and a failure originating in one of them would produce no span at all.

On the error path this placement is the better one, not a compromise: an exception passes through
`Telemetry.span`'s own handler first, so the span carries status `error` and the exception's
message before `catchAll` turns it into a `500`. The cost is that such a span has no
`http.response.status_code`, since no response ever came back to it. A query for failures has to
go by span status rather than by code. `TodoTests.Tracing` pins this.

## How the deployed export path was arrived at

Three plans died on the way, and the reasons are worth keeping so they are not re-proposed.

**A collector reading the file exporter's segments.** The collector that runs in Lambda is
`open-telemetry/opentelemetry-lambda`, whose component set is assembled in
`collector/lambdacomponents/default.go`. Its receivers are exactly two, `otlp` and `telemetryapi`.
There is nothing that reads from disk, so segment files have no reader whatever directory they are
written to. Adding one means a file in that tree selected by Go build tag, a Go toolchain in the
image build, and a fork carried indefinitely. The same list has no `resourcedetection` processor
and no AWS exporters at all: `debug`, `otlp`, `otlphttp` and `prometheusremotewrite`.

**The collector as a layer.** Lambda does not attach layers to container-image functions. Not
fatal by itself, since extensions still run from `/opt/extensions` and the layer archive can be
unpacked into the image, which was tried and worked.

**The collector at all.** With lean-telemetry v0.2.0's OTLP exporter the function could speak OTLP
to a collector on loopback, and that was built and building cleanly. It then ran into the network:
the VPC holds a VPC, two subnets and a security group, with no internet gateway, no NAT and no
route tables, so the function reaches RDS and nothing else. That is coherent with how the stack
was built, since secrets resolve at deploy time rather than at runtime, and telemetry was the
first thing ever to want egress. Worse than losing telemetry, the collector's `decouple` processor
holds an invocation open until its pipeline drains, so a collector that could not connect would
have stretched billed duration rather than failing quietly.

**What we do instead.** Lambda forwards stdout to CloudWatch Logs through the Lambda service's own
pipeline, not through the function's network interface, which is why this function logs today
despite having no egress. So `OTEL_EXPORTER_CONSOLE_FORMAT=otlp_json` puts OTLP/JSON in CloudWatch
without a collector, a NAT gateway or a VPC endpoint, and deletes work rather than adding it.
Reaching anything beyond CloudWatch later is a subscription filter's job, and that also runs
outside this VPC.

X-Ray was weighed and not chosen. `otlphttp` with the `sigv4auth` extension, both in the build,
could reach its OTLP endpoint, but that needs a VPC interface endpoint, and X-Ray embeds an epoch
timestamp in the leading bytes of a trace id where lean-telemetry generates them at random. That
would likely need ID generation changed upstream, and should be confirmed before anyone builds on
it.

## What the deployment carries because of telemetry

lean-telemetry v0.2.0 requires `leancurl` unconditionally, so its shim is linked into the binary
whichever exporter is configured, and the image has to account for it even on the stdout route.

- The build stage swaps `libcurl-minimal` for `libcurl-devel`. leancurl locates libcurl through
  pkg-config and needs the headers and the `.pc` file; the devel package conflicts with the
  minimal one the base image ships, and this image's `dnf` is microdnf, which has no
  `--allowerasing`. `dnf swap` does the exchange and works, though only in a build context: run
  under `docker run` it kills dnf, which is itself linked against the library being removed.
- The runtime stage adds nothing. `libcurl-minimal` already provides the `libcurl.so.4` the shim
  loads.
- The shim itself is copied to `/usr/lib64`. The binary loads it by name, so without it the
  function does not start at all, which is not hypothetical: the built binary refuses to load
  outside `lake env`.

## Verified

- Local traces end to end against the real database: server spans named by route template, DB
  spans sharing the request's trace id, unmatched requests with no `http.route`, migration at
  ~31ms on startup.
- `TodoTests.Tracing` covers the four claims worth pinning, using `Telemetry.Testing.capture`.
- Export failure never reaches the application. Run with `OTEL_TRACES_EXPORTER=otlp` and nothing
  listening, requests were served normally and the run produced one line of stderr rather than one
  per span. A *refused* connection fails instantly; a black-holed one would cost
  `OTEL_EXPORTER_OTLP_TIMEOUT` per export.
- The image builds, and `ldd` inside it resolves the shim, `libcurl.so.4` and `libpq` with nothing
  missing. Dropping the collector took it from 392MB to 327MB.
- `OTEL_EXPORTER_CONSOLE_FORMAT=otlp_json` emits one OTLP/JSON object per line with the resource
  attributes merged as documented.
- `sam validate --lint` passes.

## Configuration

Local development needs nothing set: console output in the readable format is the default.

Deployed, from `template.yaml`:

| Variable | Value |
|---|---|
| `OTEL_SERVICE_NAME` | `todomvc` |
| `OTEL_TRACES_EXPORTER` | `console` |
| `OTEL_LOGS_EXPORTER` | `console` |
| `OTEL_EXPORTER_CONSOLE_FORMAT` | `otlp_json` |
| `OTEL_RESOURCE_ATTRIBUTES` | `cloud.provider`, `cloud.platform`, `cloud.region`, `faas.name`, `faas.max_memory` |

`faas.instance` is supplied by the function itself through `installFromEnv`'s `extraAttrs`, since
a log stream name belongs to one execution environment and arrives in that environment.
`host.name` is undetected either way, because Lambda sets no `HOSTNAME`.

## Not yet true

- **Nothing has been deployed.** `sam deploy` has never been run. The image builds and the
  template validates, and that is the whole of the evidence.
- **CloudWatch has never been queried.** OTLP/JSON is deeply nested, so Logs Insights over
  `resourceSpans[].scopeSpans[].spans[]` will be clumsy. How clumsy is unknown, and it is the main
  thing that would push us towards a subscription filter and a real backend.
- **Ingestion cost is unmeasured.** Every span is a log line, and static assets get spans too.

## Deferred

- **`catchAll` emitting an error log record.** It swallows the exception today, which is
  reasonable while our span sits inside it and reports the cause itself.
- **W3C `traceparent` propagation.** Not implemented upstream, so our traces are always roots.
  Related: `AwsLambda.Api` discards the runtime API's `Lambda-Runtime-Trace-Id`.
- **Skipping static assets.** Every request served by `file` gets a span, and on the stdout route
  that is a log line each. `serverSpan` now takes a `skip` predicate for exactly this; we pass
  none, because it is not worth choosing a rule before the ingestion volume is known.
- **Pool-borrow timing.** Needs `Postgres.Pool` to hand out a borrow as a value rather than only
  as a bracket.

## Open questions

- `faas.version` is absent. There is no static value for it at deploy time without an alias.
- Locally the "Listening on" line is interleaved with the JSON, so the stream is not strictly
  JSONL. `LambdaMain` prints nothing, so the deployed stream should be clean, but a subscription
  filter parsing every line would need to tolerate the exception.
- lean-telemetry reports its scope version as `0.1.0` in OTLP output while the package is at
  `0.2.0`. Upstream nit.

## Noticed while instrumenting

`Todo.render` issues two `SELECT`s: the filtered list and, for the counter, the full one. On the
unfiltered page those are the same query run twice. Nothing to do with telemetry, but the traces
put it in plain sight.

## Cardinality and content

Method, route template, path, status code and client address are all safe. Todo ids are fine. Todo
**titles** are user content and must not go on spans.
