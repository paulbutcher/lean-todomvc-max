# TODO

Open items only. Anything settled has gone to the code, a comment, or a commit message.

## This repo

- **Harness helper for full-stack form posts**: GET to mint the anti-forgery token, harvest cookie
  and token, POST. Without it a test can drive a partial stack and pass vacuously, which one of
  mine did.
- A copy button on `/connect` needs ~10 lines of JavaScript, left out under the no-JS rule.

## Deployment

- **On hold.** `WWW-Authenticate` is renamed to `x-amzn-Remapped-www-authenticate` by the Lambda
  function URL, so no client sees a 401 or 403 challenge. Clients find the metadata by convention
  regardless, so this is conformance rather than something blocking anything.
  - Whether an API Gateway HTTP API fixes it is unsettled. AWS documents the remapping only for
    REST APIs, but the one first-hand test I can find reports it on HTTP API v2 as well. A
    throwaway stack and one `curl -i` answers it for pennies.
  - Not a CloudFront Function: CloudFront does not invoke viewer-response functions when the
    origin returns 400 or higher, so it would never run on our 401. Only Lambda@Edge on
    origin-response runs for those, and it is a lot of machinery for one header.
  - An ALB passes the header through, but carries a fixed monthly cost the others don't.
- Delete the `scope-diagnostic (throwaway)` client row from the deployed database.

## Upstream

- [leanprover/lean4#14934](https://github.com/leanprover/lean4/issues/14934): `URI.Query` lookups
  compare percent-encoded bytes, which are not canonical. lean-middleware works around it, so
  nothing here is blocked; if it lands, `Middleware.Params.lookup` can go back to delegating.

## Deferred

- **Prune client registrations.** DCR is the only way in now that CIMD is withdrawn, and Claude
  registers one per connection. `OAuth.Service.pruneClients` and `purgeExpired` are both offered
  and neither is called. Deferred because it needs a scheduler the stack hasn't got, to bound a
  table holding single figures.
- Rate limiting on `/oauth/register` (AUTH-20.18.2).
- `structuredContent` and `outputSchema` for `list_todos`.
- IAM database authentication instead of a self-managed password. Weighed and deferred as more
  work than the outage justified.

## Known, and not a defect

- claude.ai caches connector OAuth state against the server URL, and deleting the connector does
  not clear it. Only a new hostname does. Nothing served from here reaches that state.
- A scopeless authorization request is covered by no standing consent, so such a client is asked
  again on every re-authorization, and a scopeless `prompt=none` request can only ever answer
  `consent_required`. Neither matters until a headless client appears here.
