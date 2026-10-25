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

Email-only scenarios do not require individual mailbox-owner sign-ins. The run
page hides Teams controls and cross-user Teams instructions for those scenarios.
For mixed scenarios, only users with assigned Teams activities see the Teams
execution button; posting to that endpoint without assigned Teams work returns
an explicit error before acquiring a delegated token.

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

The default Azure demo uses an atomic JSON journal on a temporary ACI `emptyDir`
at `/app/data`. Run exactly one process/replica; local storage has no cross-process
locking. A storage failure poisons the journal and makes health/execution fail.
Never reset a surviving journal to work around duplicate detection.

Back up under restricted administrator access. Journal snapshots contain pending
message bodies and user context; keep only fictional data. No web endpoint serves
the raw journal. Retire completed/cancelled runs to clear the scenario content;
fingerprints and results remain as tombstones. The default 100-run cap includes
tombstones. Rotate/archive the journal only as an explicit administrator action,
recording replay-risk implications. There is no silent automatic deletion.

Local mode uses an atomic JSON file under DATA_DIR; use protected disk permissions
and persistent Docker volume. Never mount the same local journal into multiple
processes. Local atomic replacement does not provide cross-process locking.

Caddy's separate temporary `/data` volume holds private keys and ACME state.
There is no Azure Files share or storage account mount key. Stop/restart/update/
recreation of ACI can erase both temporary volumes. Export reports before
lifecycle changes. After journal loss, review prior mailbox/channel outcomes
manually before running any scenario: duplicate protection no longer knows
previous runs. Caddy requests new certificates after loss and can hit CA limits.

The optional Entra Blob backend remains available in application code for custom
deployments, but the default ACI template disables it and provisions no storage.

## Observability and readiness

`/healthz` returns ready only after startup user resolution and journal recovery,
and fails if the journal becomes unavailable. It contains no tenant details.
Use `az container logs` for application and Caddy operational failures,
correlating the application run ID with Graph `client-request-id`. Log Analytics
is not provisioned or connected to ACI; centralized retention is not configured.
Do not enable raw body/header logging or capture authorization-code callback URLs.

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
For default anonymous pulls, verify each image/tag is publicly pullable and
registry networking allows ACI. Do not configure registry identity credentials.
Only for opt-in private ACR pulls, verify the runtime managed identity has pull
permission on each registry (AcrPull for standard RBAC, repository reader for
ABAC registries) in the same tenant.
The existing registry is not managed or deleted by this repository's Bicep.
Incremental ARM deployment does not delete resources removed from a template.
Any storage accounts created by a storage-backed version are no longer used;
archive required records before an administrator deliberately removes them.
Key Vault and Log Analytics workspaces from older versions are also no longer
provisioned or needed by the app. Review and remove unused legacy resources
separately to avoid retaining unnecessary resources and costs. Preserve required
secrets/logs first; do not weaken a legacy vault's purge protection.
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
6. Remove dedicated pipeline federation/identity if no longer used. Azure removes
   the generated ACI DNS endpoint with the group; no custom CNAME is created.
7. If deleting a legacy Key Vault from an older deployment, its purge protection
   prevents immediate purge/name reuse; wait the configured recovery interval.
   Current templates do not create a vault. Do not disable legacy protection.

Azure infrastructure deletion does not delete tenant content already sent.
