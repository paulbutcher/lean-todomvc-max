# TODO

Loose ends, most pressing first. Written 2026-08-26.

## Next

- **Revoke button.** "Disconnect every agent" on `/connect`: iterate `store.clients`, call
  `Service.revoke account client resource` for each. Blunt on purpose; the proper list needs a
  library addition (below).
- **Then answer two questions with it.** Does a revoked token make Claude re-authorize, or does
  the loop just move from 403 to 401? And what does it actually send as `scope`, which
  `oauth.scope_requested` will show the first time authorization runs.
- Do this before anything that changes the origin. Claude's stuck empty grant is a fixture we can
  no longer manufacture, and an origin change would invalidate it by accident.

## Deployment

- **`WWW-Authenticate` is renamed to `x-amzn-Remapped-www-authenticate`** by the Lambda function
  URL, so no client sees a 401 or 403 challenge. Try an API Gateway HTTP API first, since it is
  cheap to falsify with a throwaway stack; else CloudFront with a viewer-response function that
  renames it back. Either changes the origin, which invalidates every token.
- **Put the reason in the response body too.** Independent of the above and worth doing anyway: a
  JSON-RPC error saying which scopes are needed survives what the header does not.
- Delete the `scope-diagnostic (throwaway)` client row from the deployed database.

## lean-authentication

Four defects, one feature. All need your say-so before I write specs.

- `client_id_metadata_document_supported` is advertised unconditionally. Make `ClientDocuments`
  optional in `Ports` and derive the flag, so a deployment cannot advertise what it has no adapter
  for.
- A scopeless authorization request silently grants nothing, which is neither of the two answers
  OAuth 2.1 §3.2.2.1 permits.
- A token with an empty scope set is issued and refreshed. This is the one that cost the night: a
  credential that can do nothing reads as success and the client refreshes it forever.
- `conclude` accepts `.granted prompt []`. A grant of nothing is a denial however it arrived.
- **Feature:** no way to enumerate an account's live connections. `Service.grants` reads consent
  history, which misses any grant made without a consent prompt. Blocks the proper revoke page.

If the four land, four workarounds here can go: the `metadata` merge, `withDefaultScopes`, the
empty-scope half of the `token` guard, and the `decisionFor` guard.

## Other libraries

- `Std.Http`'s `URI.Query.find?` compares *encoded* bytes, so a lookup key encoded one way never
  matches a client's equivalent encoding. `Middleware.Params.get` inherits it. Raise upstream, or
  have lean-middleware compare decoded names.

## This repo

- **`withParams` combinator** mirroring `guarded`: handlers take `Params`, absence answers 500.
  Absent middleware and absent field are different facts and currently both read as false. Half an
  hour, deletes code.
- **Harness helper for full-stack form posts**: GET to mint the anti-forgery token, harvest cookie
  and token, POST. Without it a test can drive a partial stack and pass vacuously, which one of
  mine did.
- **Two theorems worth stating.** Factor the consent reading into a pure `decide` and prove a
  grant is never empty; prove every tool `Mcp.permitted` offers is admitted by the held scopes.
- Decide whether `mcp call authorized` stays. It fires per call and duplicates the span; the three
  refusal lines are rare and worth keeping.
- README's "Bringing your own agent" is down to one paragraph. `/connect`, the two scopes, and the
  fact that CIMD is not offered are all undocumented.
- Offered and not added: a CLAUDE.md line that an `Option` whose `none` means "misconfigured" must
  never default into a value meaning "the caller asked for nothing".
- A copy button on `/connect` needs ~10 lines of JavaScript, left out under the no-JS rule.

## Deferred

- Rate limiting on `/oauth/register` (AUTH-20.18.2).
- `OAuth.Service.purgeExpired` and `pruneClients` are offered and never run.
- `structuredContent` and `outputSchema` for `list_todos`.
- IAM database authentication instead of a self-managed password. Weighed and deferred as more
  work than the outage justified.
- `scratchpad/cimd-fetcher-spec.md` is moot: with no egress from that VPC a fetcher could never
  fetch. Bin it.
