# TodoMVC

See: [Formally verified CRUD](https://paulbutcher.com/lean2.html)

A Lean implementation of [TodoMVC](https://todomvc.com).

## Reading a deployed function's telemetry

Spans and log records leave as one JSON object per line, so that the CloudWatch log group can be
queried rather than only read. `lake exe logs` renders them back into the form a terminal wants:

```
sam logs --stack-name todomvc --tail | lake exe logs
```
