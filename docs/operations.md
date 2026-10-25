# Operations

## Before enabling delivery

Confirm the CDX tenant, licenses, channel membership, five resolved object IDs,
operator allowlist and scope tests. Verify the sixth test mailbox is out of scope.
Remove any broad Entra Mail.Send assignment from the runtime principal.
Keep external recipients disabled. Run the sample dry-run and inspect each
planned Graph operation before approving a new executable scenario.

## Execution, retries and reports

An operator starts/resumes email batches. Each Teams author signs in separately,
executes ready activities as themselves, then signs out. Revisit after cross-user
dependencies finish. Resume email after Teams if needed; repeated clicks reuse
the same run and do not replay completed/failed/unknown steps.

Status: pending, running, success, failed, unknown, cancelled, skipped.
Success means Graph accepted the request (mail 202 is not confirmed delivery).
HTTP 429 is an explicit rejection and is retried at most three times, respecting
Retry-After seconds or HTTP date up to a 60-second per-wait budget. GET resolution
also retries 502/503/504. POST 5xx/network failures are ambiguous, never retried.
All Graph calls have connect/overall timeouts. Failed/unknown dependencies skip
descendants. There is no automatic retry button that could duplicate remote mail.

Cancellation prevents only pending actions. An HTTP request already in progress
may complete; cancellation cannot retract mail or a Teams post.
On shutdown workers are cancelled; running journal entries become unknown on
restart. Inspect remote outcome before an administrator deliberately creates a
replacement scenario. A new scenario ID is not a substitute for outcome review.

Each report includes a run/correlation ID and per-step idempotency keys. It
excludes message bodies, recipients, access tokens and raw Graph responses.
Application audit logs contain event, run, activity ID and status only. OAuth
callback query logging and HTTP-library debug logs are disabled.

## Storage and retention

Azure uses a private Blob (`journal/runs.json`) with Entra auth and conditional
ETag replacement. Run exactly one process/replica. A competing writer or storage
failure poisons the journal and makes health/execution fail; investigate, stop
the competing instance, then restart. Never ignore or reset the journal to
work around duplicate detection.

Back up under restricted administrator access. Journal snapshots contain pending
message bodies and user context; keep only fictional data. No web endpoint serves
the raw journal. Retire completed/cancelled runs to clear the scenario content;
fingerprints and results remain as tombstones. The default 100-run cap includes
tombstones. Rotate/archive the journal only as an explicit administrator action,
recording replay-risk implications. There is no silent automatic deletion.

Local mode uses an atomic JSON file under DATA_DIR; use protected disk permissions
and persistent Docker volume. Never mount the same local journal into multiple
processes. Local atomic replacement does not provide cross-process locking.

Caddy's certificate share contains private keys and ACME state. Protect backups,
avoid deleting it during updates, and rotate the storage account mount key
through an ACI update if exposed. Blob journal and certificate accounts are
deliberately separate.

## Observability and readiness

`/healthz` returns ready only after startup user resolution and journal recovery,
and fails if the journal becomes unavailable. It contains no tenant details.
ACI diagnostics feed Log Analytics; use container logs for operational failures,
correlating the application run ID with Graph `client-request-id`. Do not enable
raw body/header logging or capture authorization-code callback URLs.

Check Caddy TLS renewal logs and HTTPS health regularly. Web client authentication
is secretless; Azure Identity refreshes managed-identity assertions in memory.
Federation trust changes can take time to propagate. No distributed
session store is provided; users must sign in again after replacement.

## Upgrade

Review hash-locked Python dependencies, pinned Caddy/base image versions and
security advisories. Run CI and tenant-scope smoke checks before enabling
delivery. Manually build/push both images to their configured registry locations.
`azd deploy` consumes `config/container-images.json` without building or pushing.
For predictable updates change the tag/digest rather than overwriting an unchanged
reference: ACI may not refresh an image when the declaration has not changed.
Verify the runtime managed identity has pull permission on each configured
registry (AcrPull for standard RBAC, repository reader for ABAC registries).
The existing registry is not managed or deleted by this repository's Bicep.
Never change user/resource mappings while expecting old plans to remain valid;
the configuration fingerprint intentionally blocks such runs.

## Teardown and revocation

1. Disable delivery and cancel pending runs. Wait for in-flight actions.
2. Export redacted reports and protect/archive the journal if required.
3. Remove application-specific Exchange role assignments/scope and
   service-principal pointer after checking they are not shared:
   `Remove-ManagementRoleAssignment`, `Remove-ManagementScope`,
   `Remove-ServicePrincipal`.
4. Revoke delegated consent/assignments and delete the dedicated web registration.
   Remove runtime Graph role grants and the web registration's federated trust.
5. Run `azd down`; the hook-created ACI group is in the deleted resource group.
6. Remove custom DNS and dedicated pipeline federation/identity if no longer used.
7. Key Vault purge protection prevents immediate purge/name reuse; wait the
   configured recovery interval. Do not disable protection to simplify teardown.

Azure infrastructure deletion does not delete tenant content already sent.
