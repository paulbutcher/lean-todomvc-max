# TODO

Loose ends, most pressing first. Written 2026-08-26.

## Next

Both clients now work end to end: Claude Code and claude.ai each register, consent, exchange and
call the tools against the deployed endpoint. What is left below is tidying, not unblocking.

- **Prune client registrations.** DCR is the only way in here now that CIMD is withdrawn, and
  Claude registers one per connection. `OAuth.Service.pruneClients` is offered by the library and
  nothing calls it. Seven have accumulated from debugging alone.
- Worth recording, since it cost a night: claude.ai caches per server URL and deleting a connector
  does not clear it. It held a stuck grant across one delete and "expired" across another, and
  revoking every grant server-side did not shift it. Moving the function URL did, first try. A new
  hostname is the only lever there is on that state.
- Claude Code's authorization request names `todos:read todos:write` outright, so a client that
  names no scopes is claude.ai's behaviour rather than the norm. The prompt default exists for
  that one client.

## Deployment

- **On hold.** `WWW-Authenticate` is renamed to `x-amzn-Remapped-www-authenticate` by the Lambda
  function URL, so no client sees a 401 or 403 challenge. Clients find the metadata by convention
  regardless, so this is conformance rather than the thing that was blocking anything.
  - Whether an API Gateway HTTP API fixes it is unsettled. AWS documents the remapping only for
    REST APIs, but the one first-hand test I can find reports it on HTTP API v2 as well. A
    throwaway stack and one `curl -i` answers it for pennies.
  - Not a CloudFront Function: CloudFront does not invoke viewer-response functions when the
    origin returns 400 or higher, so it would never run on our 401. Only Lambda@Edge on
    origin-response runs for those, and it is a lot of machinery for one header.
  - An ALB passes the header through, but carries a fixed monthly cost the others don't.
- **Put the reason in the response body too.** Independent of the above and worth doing anyway: a
  JSON-RPC error saying which scopes are needed survives what the header does not.
- Delete the `scope-diagnostic (throwaway)` client row from the deployed database.

## lean-authentication

Pinned at `v0.12.0`. Every spec written this session has landed, and every workaround they were
written to remove is gone: the `token` guard, the `decisionFor` guard, the `metadata` merge and
the `noDocuments` port. `disconnect` now uses `Service.connections`, so it is account-scoped and
its count is true.

- `withDefaultScopes` now amends the prompt rather than the request, on `ConsentPrompt.answered`.
  One consequence to watch: a scopeless request is covered by no standing consent, so such a
  client is asked again on every re-authorization, and a scopeless `prompt=none` request can only
  ever answer `consent_required`. Neither matters until a headless client appears here.

## Other libraries

Pinned at lean-middleware `v0.10.0`, which took both specs written for it: handlers can require
an extension, and `Params.get` looks a name up decoded. The local `withParams` is gone in favour
of `Middleware.withParams`.

- **Raised upstream** as [leanprover/lean4#14934][]: `URI.Query` lookups compare percent-encoded
  bytes, which are not canonical, so the same mismatch waits for anyone using `Query.get`, `getD`,
  `findAll`, `contains` or `erase` directly. lean-middleware works around it rather than
  inheriting it, so nothing here is blocked. If it lands, `Middleware.Params.lookup` can go back
  to delegating.

[leanprover/lean4#14934]: https://github.com/leanprover/lean4/issues/14934
- `approvalField` keeps its base64url. It is no longer a workaround: a scope is an opaque string
  the client chose, and encoding puts the field name beyond that choice.

## This repo

- **Harness helper for full-stack form posts**: GET to mint the anti-forgery token, harvest cookie
  and token, POST. Without it a test can drive a partial stack and pass vacuously, which one of
  mine did.
- Three theorems now state what `Mcp.permitted` does, in `TodoTests/Mcp.lean`. `Todo/Mcp.lean`
  became `@[expose]` to allow it, which was free there: it has no private declarations.
- Decide whether `mcp call authorized` stays. It fires per call and duplicates the span; the three
  refusal lines are rare and worth keeping.
- README's "Bringing your own agent" does not name the two scopes. Probably right: `/connect`
  explains them to the person granting them, and the README is not where that decision is made.
  Close this unless a reason to say them appears.
- Offered and not added: a CLAUDE.md line that an `Option` whose `none` means "misconfigured" must
  never default into a value meaning "the caller asked for nothing".
- A copy button on `/connect` needs ~10 lines of JavaScript, left out under the no-JS rule.

## Deferred

- Rate limiting on `/oauth/register` (AUTH-20.18.2).
- `OAuth.Service.purgeExpired` is offered and never run. `pruneClients` has moved up to Next.
- `structuredContent` and `outputSchema` for `list_todos`.
- IAM database authentication instead of a self-managed password. Weighed and deferred as more
  work than the outage justified.
- `scratchpad/cimd-fetcher-spec.md` is moot: with no egress from that VPC a fetcher could never
  fetch. Bin it.
