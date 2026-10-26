# Scenario format v1.0

Canonical format: one UTF-8 YAML document, `.yaml` or `.yml`, default 65536-byte
maximum. Accepted MIME types are `application/yaml`, `application/x-yaml`,
`text/yaml`, `text/x-yaml`, `text/plain` and `application/octet-stream`.
Browsers may label YAML as `application/octet-stream`; it is accepted only with
a `.yaml`/`.yml` filename and must still pass UTF-8, YAML and scenario validation.
JSON MIME types remain rejected.
MIME/extension checks are only an early filter, not the security boundary.
Aliases, anchors, explicit tags, duplicate keys, non-string mapping keys,
non-JSON values and executable expressions are forbidden.

The [JSON Schema](../schemas/demo-scenario.schema.json) is generated from
[models](../src/demo_loader/models.py). Additional properties are forbidden.

| Field | Contract |
|---|---|
| schemaVersion | quoted `"1.0"` |
| scenarioId | unique `[a-z][a-z0-9_-]{0,39}`; retained for replay prevention |
| title / description / author | bounded display text; never executed |
| createdAt | quoted ISO 8601 timestamp with timezone; metadata, not sent date |
| tenantAssumptions | 1..20 plain-text tenant preparation statements |
| requiredUsers | 1..5 distinct configured logical keys; includes every author |
| requiredChannels | distinct configured aliases, required for Teams |
| dryRun | default true; immutable dry-run-only safety gate when true |
| metadata / tags | optional bounded labels |
| activities | 1..200 discriminated typed activities |

Common activity fields: unique `id`, `type`, `user`, `body`, `dependsOn` (earlier
IDs only), `delaySeconds` (0..3600). Lists are ordered; independent ready actions
can run concurrently. Add explicit dependencies where message order matters.
Delay is relative to the latest dependency completion, or run start for roots.

## Email

`type: email`, `to` (1..10), `cc` (0..10), `subject`, `bodyType: text|html`,
`importance: low|normal|high`. Recipients must be **logical keys**, not arbitrary
addresses, by default. Only an administrator's ALLOW_EXTERNAL_RECIPIENTS opt-in
permits validated email addresses. Both To and Cc are checked.

HTML is sanitized to formatting-only p/br/b/strong/i/em/ul/ol/li with no attributes,
links or images. The web preview escapes even sanitized HTML, showing source.
Mail is a new message; threading/reply APIs and attachments are unsupported.
No historical sent times are supported; a delay schedules future real delivery.

## Teams

`type: teamsMessage`, `channel` alias and plain-text `body`.
`type: teamsReply` additionally requires `parent`, naming an earlier root
teamsMessage in the **same channel**, also listed in `dependsOn`.
Replies to replies, chats, bots, migration operations and impersonation are not
implemented. Each author must authenticate interactively and authorize their
background messages once for the started run. Authorized workers wait across
cross-user dependencies and continue with browsers closed, renewing tokens in
server memory before sends. Interaction requirements pause the author for
sign-in; permission or Graph failures can prevent completion. Workers and tokens
do not survive application restart. Explicit logout revokes that session's future
sends; operator cancellation stops pending work for the run.

## Placeholders

Only `{{user.adele.displayName}}` and
`{{user.adele.userPrincipalName}}` forms, with any configured key, in body/subject.
Literal replacement occurs before HTML sanitation, never through Jinja or eval.
Recipients already use keys; do not put placeholders in recipient fields.
Unknown keys or other expression delimiters are rejected.

## Resource mapping

Keep actual IDs in the administrator's configuration, not scenarios:

```yaml
channels:
  launch:
    teamId: "<existing-team-UUID>"
    channelId: "19:<existing-channel-value>@thread.tacv2"
```

The mapping IDs must pass typed validation. No broad team/channel discovery
permission is requested; Graph checks actual access at execution.
Startup validates exactly five unique user slots, resolves each UPN, and fails
on ambiguous/missing users. A changed user/resource/tenant/recipient-policy
fingerprint blocks old runs from executing against different mappings.

## Examples and validation

- [Valid default](../examples/demo-scenario.yaml): email only, no channel mapping needed.
- [Assisted Teams](../examples/teams-assisted.yaml): map `launch` first.
- [Invalid](../examples/demo-scenario-invalid.yaml): deliberately rejected.
- [Skill example](../skills/demo-scenario-creator/examples/scenario.yaml).

```powershell
python -m demo_loader.cli .\scenario.yaml
```

Validation is offline: no Graph calls. JSON Schema alone cannot verify dependency
graphs, referenced keys, tenant policy or current resource access. The app and CLI
add these checks (actual channel access is confirmed only by Graph).
