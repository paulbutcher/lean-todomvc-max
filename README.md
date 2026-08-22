# TodoMVC

See: [Formally verified CRUD](https://paulbutcher.com/lean2.html)

A Lean implementation of [TodoMVC](https://todomvc.com).

## The assistant panel

The panel beside the list talks to a model on Amazon Bedrock, which is given tools to read and
change the todos of whoever is signed in. It reads the usual `AWS_*` variables, so during
development anything that puts credentials in the environment will do:

```
eval "$(aws configure export-credentials --profile <profile> --format env)"
export AWS_REGION=<region>
```

`BEDROCK_MODEL` picks the model, and without it the client's own default applies. The model has to
be enabled in that region first, and the id may be a cross-region inference profile rather than a
foundation model, which is why it is configuration rather than a constant.

Nothing needs any of this to be set to run the server: a turn that cannot be signed reports that
in the panel, and the list itself works either way.

## Reading a deployed function's telemetry

Spans and log records leave as one JSON object per line, so that the CloudWatch log group can be
queried rather than only read. `lake exe logs` renders them back into the form a terminal wants:

```
sam logs --stack-name todomvc --tail | lake exe logs
```
