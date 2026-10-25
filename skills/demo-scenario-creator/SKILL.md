---
name: demo-scenario-creator
description: "Use when creating fictional Microsoft 365 CDX demo scenario YAML for the azd-m365-demo-loader, including five-user email, assisted Teams channel conversations, chronology, dependencies, and schema validation."
---

# Demo scenario creator

## Purpose and when to use

Create portable, consistent, fictional business-demo scenarios for upload to the
Microsoft 365 demo loader. Use for planning Outlook email and Teams channel
conversations, not for sending messages yourself. The output is data, never code.

## Inputs

Required: fictional business topic, desired narrative, five configured user keys,
and allowed channel aliases (if any Teams messages are requested).
Default logical keys are **adele, alex, christie, diego, megan**. If the operator
changed configuration, use only the supplied replacement keys, exactly five.

Optional: title, scenario ID, author, timezone-aware creation date, tags,
plain-text or formatting-only HTML emails, recipient lists, importance, relative
delays, activity count (maximum 200), and whether the operator explicitly wants
an executable scenario. Default to `dryRun: true`.

## Supported schema version and activities

Use `schemaVersion: "1.0"` only. Do not invent properties or future versions.
Supported types:

- `email`: `user`, `to`, optional `cc`, `subject`, `body`, optional `bodyType`
  (`text` or `html`) and `importance` (`low`, `normal`, `high`).
- `teamsMessage`: `user`, `channel`, `body`.
- `teamsReply`: `user`, `channel`, `parent`, `dependsOn`, `body`. Parent must be
  an earlier **root teamsMessage**, in the same channel, and in `dependsOn`.

All activities have a unique `id`, logical `user`, optional `dependsOn` (earlier
IDs only) and `delaySeconds` (integer 0..3600). Delays are relative to completion
of all dependencies, or run start for activities without dependencies.

Unsupported: email reply APIs/thread preservation, chat, attachments, calendar,
historical timestamps, arbitrary recipients, bots, scripts, shell, expressions,
password collection, and silent Teams impersonation. Emails are sent by a
scoped application. Teams messages require the assigned user to sign in and
click execution; five authors require five interactive sign-ins. Do not request
`Teamwork.Migrate.All` or claim migration APIs send normal demo messages.

## Writing and safety rules

1. Use only fictional, harmless business data. Never output passwords, secrets,
   access/refresh tokens, tenant credentials, real confidential data, or tenant
   object IDs. Do not include real customer or employee information.
2. `requiredUsers` lists every activity author and must be a subset of the
   configured five logical keys. All `to` and `cc` entries are logical keys from
   those five users, never email addresses. User names belong to configuration.
3. Use channel aliases in `requiredChannels` and activities, never Team/channel
   object IDs. Every used alias must be supplied by the operator and declared.
4. IDs and keys match `[a-z][a-z0-9_-]{0,39}`. IDs are unique within the scenario.
   Use a new scenario ID for a genuinely new narrative; do not change IDs just
   to bypass replay protection.
5. Every dependency references an earlier activity; no forward references or
   cycles. Replies explicitly depend on their root message.
6. Keep chronology realistic, with clear question/answer continuity. Do not
   imply an email has arrived merely because sendMail was accepted. Delays do
   not change historical sent dates.
7. Placeholders are limited to literal `{{user.adele.displayName}}` and
   `{{user.adele.userPrincipalName}}` forms, substituting any configured key.
   Do not use Jinja, calculations, macros, YAML aliases, anchors, tags, duplicate
   mapping keys, multiple YAML documents, or executable content.
8. Teams bodies are plain text. Prefer plain-text email. Optional HTML allows
   only p, br, b, strong, i, em, ul, ol, li; no images, links, styles or scripts.
9. Quote timestamps and version strings. `createdAt` requires a UTC offset.
   Include at least one `tenantAssumptions` item describing the isolated demo
   tenant. Include author, title, scenarioId and activities.
10. When asked for a **final scenario**, return **only valid YAML**, with no
    Markdown fences, explanations, credentials or deployment instructions.

## Complete valid example

This example works without any channel mapping.

```yaml
schemaVersion: "1.0"
scenarioId: fictional-launch-review
title: Fictional launch review
description: Two harmless coordination emails for the configured demo team.
author: Demo operator
createdAt: "2026-10-01T09:00:00Z"
tenantAssumptions:
  - Isolated licensed CDX demo tenant; five mailboxes configured and scoped.
requiredUsers: [adele, alex, christie, diego, megan]
requiredChannels: []
dryRun: true
metadata:
  purpose: fictional-demo
tags: [launch, review]
activities:
  - id: kickoff
    type: email
    user: adele
    to: [alex, christie]
    cc: [diego, megan]
    subject: Fictional launch review
    body: "Hello {{user.alex.displayName}}, please review the fictional launch checklist."
  - id: followup
    type: email
    user: megan
    to: [adele, alex, christie, diego]
    subject: Fictional launch review follow-up
    body: The demo checklist is ready for discussion. No customer data is included.
    dependsOn: [kickoff]
    delaySeconds: 120
```

## Validation checklist

- Schema version exactly "1.0"; all required top-level fields; no extra keys.
- Exactly the operator-supplied logical user vocabulary; recipients use keys.
- Unique scenario/activity IDs; prior dependencies only; no cycles.
- Each reply points to an earlier root in the same channel and depends on it.
- Channel aliases are declared and configured outside the scenario.
- Realistic chronology and consistent fictional business narrative.
- No secrets, tenant identifiers, confidential data, tags/anchors or expressions.
- `dryRun: true` unless execution was explicitly requested.
- Validate against [the bundled schema](./schema/demo-scenario.schema.json).
- Run `python -m demo_loader.cli <scenario.yaml>` in the loader repository:
  JSON Schema alone cannot prove cross-reference, safety or tenant-policy rules.
- Preview resolved identities/operations before the operator enables real sends.

## Portability

This is declarative Markdown with conventional name/description frontmatter.
It does not claim a proprietary Cowork import mechanism. If Cowork does not
support importing a skill directory, attach this text, the schema and the example
as task context. Platform capabilities and tenant policy must be checked by the
operator. Never claim the skill itself has Graph access.
