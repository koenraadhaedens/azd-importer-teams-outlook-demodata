# Architecture and trust boundaries

See the [README diagram](../README.md#architecture) and
[decisions](decisions.md). One Uvicorn process serves accessible Jinja pages.
Uploaded YAML passes bounded UTF-8 decoding, token restrictions, duplicate-key
checking, JSON Schema, Pydantic graph checks, user/resource policy, literal
placeholder resolution and HTML sanitation. The preview shows the resulting
data, never renders uploaded templates, and never executes scenario code.

## Caddy in front of the application

[Caddyfile](../Caddyfile) is the shared source of reverse-proxy configuration.
ACI loads it as a read-only volume with deployment-supplied environment values.
Caddy listens on 443 and redirects port 80; only these ports are public.
FastAPI listens on the group's network but port 8000 is not published by ACI.
Caddy proxies to `127.0.0.1:8000`. Compose uses `app:8000`, with **no app ports**.
The server ignores forwarded headers; templates use relative assets and OAuth
URLs use the explicitly configured HTTPS origin, avoiding spoofing/mixed content.

Public ACME requires a controlled hostname resolving to the group and reachable
80/443. Do not assume ACI's generated domain qualifies for public certificate
issuance. Caddy automatically renews certificates; Azure Files stores TLS state
across ACI replacement and avoids repeated issuance/rate-limit problems.

The certificate-only storage account uses an account key because ACI's Azure
Files volume contract requires one. Bicep obtains it server-side using listKeys;
it is never committed, exported, passed to the app, or supplied by the operator.
The journal account instead disables shared-key Blob authentication and uses
managed identity. TLS keys should be treated as credentials when backing up or
deleting the certificate share.

## Container image configuration

[config/container-images.json](../config/container-images.json) is the shared
source for application and Caddy image references. Compose extends its service
entries; Bicep loads their image values as defaults; the smoke script reads them
unless explicit test overrides are supplied. The deploy hook does not build or
publish images, and infrastructure no longer creates an unused ACR.

Both defaults use the existing `acrdefcontainer.azurecr.io` registry. The runtime
identity requires administrator-granted pull permission there. ACI registry
credential entries are derived from both references and deduplicated, so changing
either image registry does not silently leave Caddy without pull credentials.
No registry passwords are stored. Role assignments on existing registries remain
administrator-managed. App default without a tag uses `latest`; immutable release
tags/digests are preferable for reliable updates.

## Data flow and persistence

Startup uses ACI's user-assigned managed identity and resolves five UPNs with
Graph. Failure prevents readiness. The web app uses a managed-identity token for
AzureADTokenExchange as its federated MSAL client assertion; there is no stored
web credential or Key Vault read. A pre-authorized deployment identity creates
the registration/URLs/trust in the azd postprovision hook; administrator consent
and enterprise assignments remain separate. Operator upload stores a normalized scenario
and SHA-256 fingerprint. Each step has its own idempotency key.

Before Graph writes, the journal persists running state. Local storage uses
fsync plus atomic replace; Azure Blob uses ETag conditional replacement.
Conflicting writes/storage errors stop the process from accepting further
execution. On restart running becomes unknown. This prevents automatic retries
after a crash with uncertain remote outcome. It does not prove delivery or
remote exactly-once semantics.

Tokens are not in the journal. MSAL session caches and delegated tokens are
memory-only. Blob content includes pending bodies; reports and audit records
exclude them. Retirement clears scenario content but retains fingerprint,
scenario ID, step results and tombstones.

## Hosting alternatives

ACI is not a managed web platform. For private networking, managed ingress,
WAF, strong per-client rate limits, zero-downtime updates or high availability,
put private ACI behind Application Gateway/WAF with an appropriate certificate,
or move the app to an appropriate managed web host. That is intentionally not
the default small POC. Azure Front Door needs an explicit origin-lockdown design;
do not expose a parallel unauthenticated/bypass HTTP path.

Structured console audit events go to ACI/Log Analytics without message bodies.
Application Insights auto-instrumentation is intentionally not enabled because
capturing OAuth URLs, tokens, request content and user data needs careful
tenant-specific telemetry redaction. The Log Analytics workspace is provisioned
and wired to ACI diagnostics.
