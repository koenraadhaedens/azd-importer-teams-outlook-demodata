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

The postprovision hook first verifies the runtime identity and assigns/reuses
its Graph application User.Read.All role using the preauthorized deployer.
It then creates the group with a dormant app and HTTP-only
Caddy 503 using the same configured images, identity, volumes and port layout.
It reads the actual Azure FQDN and registers matching Entra URLs, persisting the
host/client ID in azd. Final deployment enables the app and Caddy ACME for that
FQDN; public resolution and reachable 80/443 are required. No custom DNS is
needed. Existing groups are not reset to initialization mode on reruns. Hostname
drift blocks final deployment until provisioning reconciles Entra.
Caddy automatically renews certificates using a temporary `emptyDir` at `/data`.
The app has a separate `emptyDir` at `/app/data` for its local JSON journal;
Caddy does not mount it. An initializer reuses the configured Alpine Caddy image
to set that directory's ownership to the app's nonroot UID/GID 10001 and mode 700.
No extra image, storage account, account key or Blob permission is required.

This intentionally follows the simple
[Odoo ACI demo](https://github.com/koenraadhaedens/azd-erp-crm-odoo-mcp-demo) pattern.
Temporary state is not durable across ACI lifecycle changes: stopping, restarting,
updating or recreating the group can lose certificates and execution history.
Caddy requests certificates again after loss, subject to CA rate limits. Lost
journal tombstones cannot prevent duplicate sends. Export reports and review
remote outcomes before running scenarios after storage loss.

## Container image configuration

[config/container-images.json](../config/container-images.json) is the shared
source for application and Caddy image references. Compose extends its service
entries; Bicep loads their image values as defaults; the smoke script reads them
unless explicit test overrides are supplied. The deploy hook does not build or
publish images, and infrastructure no longer creates an unused ACR.

Both defaults use the existing `acrdefcontainer.azurecr.io` registry and are
pulled anonymously. The default ACI configuration supplies an empty registry
credential list; it does not attempt managed-identity authentication against a
registry in another tenant. Runtime managed identity remains attached for Graph
and web-app federation.

Private same-tenant ACR pulls are an explicit opt-in with
USE_MANAGED_IDENTITY_FOR_IMAGE_PULL=true. Only then are registry credential entries
derived from both references and deduplicated. Registry role assignments remain
administrator-managed. No registry passwords are stored. App references without
a tag use `latest`; immutable release tags/digests are preferable for updates.

## Data flow and persistence

Startup uses ACI's user-assigned managed identity and resolves five UPNs with
Graph. Failure prevents readiness. The web app uses a managed-identity token for
AzureADTokenExchange as its federated MSAL client assertion; there is no stored
web credential or Key Vault read. A pre-authorized deployment identity creates
the registration/URLs/trust and grants runtime User.Read.All in postprovision;
delegated Teams consent, Exchange scope and enterprise assignments remain
separate. Operator upload stores a normalized scenario
and SHA-256 fingerprint. Each step has its own idempotency key.

Before Graph writes, the journal persists running state using fsync plus atomic
JSON replacement on the temporary app volume. Storage errors stop execution.
While that journal remains available, interrupted running steps become unknown
instead of being automatically retried. This protection does not survive volume
loss and does not prove delivery or remote exactly-once semantics. The code's
optional Blob backend remains available for custom deployments, but default ACI
explicitly sets JOURNAL_BLOB_URL empty and does not provision Azure Storage.

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
