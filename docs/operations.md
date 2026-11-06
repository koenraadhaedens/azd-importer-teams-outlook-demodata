# Operations

## Before enabling delivery

Confirm the CDX tenant, licenses, channel membership, five resolved object IDs,
operator allowlist and scope tests. Verify the sixth test mailbox is out of scope.
Remove any broad Entra Mail.Send assignment from the runtime principal.
Keep external recipients disabled. Run the sample dry-run and inspect each
planned Graph operation before approving a new executable scenario.

## Execution, retries and reports

An operator starts the run and its background email worker. Each Teams author
signs in separately and clicks **Start / resume my background Teams messages**
once for that run. This authorizes all of that author's pending Teams activities,
not just the currently ready ones. Workers wait on dependencies and delays and
wake automatically as other users' activities finish. The email worker also
waits for Teams dependencies. Repeated clicks do not replay completed steps.

Browsers can be closed after authorization. Use isolated browser profiles for
parallel author sign-ins: incognito windows in the same browser can share cookies.
Do not sign out to switch authors while expecting that session's background work
to continue: explicit sign-out revokes future sends authorized by that session.
Operator cancellation stops future work for the whole run.

### Open isolated sign-ins from Windows

After deploying the updated app, run this helper on your **Windows desktop**
(not Azure Cloud Shell). Copy the app base URL and the run ID from the run page's
`/runs/<run-id>` address:

```powershell
.\scripts\open-teams-signins.ps1 `
    -Url "https://your-app.westeurope.azurecontainer.io" `
    -Config ".\config\config.local.json" `
    -RunId "your-run-id"
```

By default this opens Edge for every user in `x-demo.users`. Use
`-UserKeys adele,alex` to open only the Teams authors you need, `-Browser Chrome`
to use Chrome, or `-BrowserPath "C:\path\to\msedge.exe"` for a nonstandard install.
`-Config` defaults to `DEMO_CONFIG_FILE`, then `config\config.local.json`.
Omit `-RunId` to land on the run list instead.

Each user gets a separate, fresh user-data directory and private window, rather
than multiple private windows sharing one profile. The app supplies Microsoft's
`login_hint` and requests interactive authentication; ordinary sign-in without a
hint still uses the account picker. The hint is not an authorization grant.
Microsoft/tenant policies determine the password, MFA or passwordless screens;
the helper cannot bypass them or guarantee a particular screen.

After sign-in, each user must still click **Start / resume my background Teams
messages**. The script does not read passwords, automate consent, or send messages.
Do not sign out while work is pending. Fresh profile directories are printed by
the helper and are not automatically deleted; close all their windows before
manually deleting the printed invocation folder. Treat browser profile files as
sensitive even though private browsing reduces retained sign-in data. Managed
browser policies that disable private mode or override profile isolation may
prevent this workflow.

Before each Teams send, MSAL obtains a current access token from its memory-only
cache, using a refresh token when necessary. Sign-in requests `offline_access`;
existing users must sign in again with the updated consent. A run-author worker
retains its session cache independently of the browser cookie's one-hour expiry,
only while that worker is active. Tokens are never written to the journal.
The run page/report shows background worker states, including
`waiting_for_dependencies`, `authorization_required`, `reauthentication_required`
and `failed`. The page refreshes those states, but keeping it open is unnecessary.
If silent renewal requires interaction, that author's worker pauses with pending
steps intact and a visible sign-in instruction. Sign in and authorize the same
run again; other authors can remain waiting. Failed/unknown Graph sends are not
automatically replayed. Microsoft revocation, Conditional Access, network or
permission failures can still prevent completion.

Background work is not restart-durable. After an app/container restart, the
operator must resume the run and each unfinished Teams author must authorize it
again. Preserve completed-step records; never create a new run just to retry
unknown remote outcomes.

Email-only scenarios do not require individual mailbox-owner sign-ins. The run
page hides Teams controls and cross-user Teams instructions for those scenarios.
For mixed scenarios, only users with assigned Teams activities see the Teams
background authorization button; posting without assigned Teams work returns
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
`azd deploy` reads the ignored private file selected by `DEMO_CONFIG_FILE`
(default `config/config.local.json`) without building or pushing. Settings are
injected through ACI secure environment values; the shared image contains none.
Changing users/channels requires reviewing corresponding Entra/Exchange grants
and redeploying, not rebuilding. Existing runs are bound to their configuration
fingerprint and must not be resumed against changed mappings without review.
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
