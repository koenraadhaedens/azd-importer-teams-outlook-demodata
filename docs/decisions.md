# Architectural decisions

## 1. Teams: assisted delegated execution (Modes C + A)

Each demo user signs in separately and executes only their own ready activities.
`ChannelMessage.Send` supports normal channel messages and replies as that user.
Dependencies can cross users; pending actions remain visible until the appropriate
user signs in. The application never silently impersonates the five users.
Chat creation and email reply/thread APIs are deliberately unsupported in v1.
No `Teamwork.Migrate.All`, bot, beta endpoint, or password grant is used.

## 2. Separate interactive and application identities

An Entra confidential web app performs OIDC sign-in and delegated Teams calls.
A user-assigned managed identity resolves the five users using application
`User.Read.All` and sends mail through Graph `/users/{id}/sendMail`.
Runtime is Azure ACI only; local development is limited to offline/mock checks.
Managed identity conveys no Graph permissions by itself.

The web app authenticates using a lazy MSAL client assertion obtained from the
container's user-assigned identity for `api://AzureADTokenExchange/.default`.
A federated identity credential on the web registration trusts that identity's
principal ID in the same tenant. No web secret, local credential fallback or
Key Vault read is used. Provision retains the vault for future secrets without
granting the runtime access.

The azd noninteractive postprovision hook registers the app, URLs and federation
using a **separate pre-authorized deployment identity**. It requests but does not
consent to ChannelMessage.Send, creates an assignment-required enterprise app,
and saves WEB_CLIENT_ID. Administrator consent/user assignments remain explicit
manual steps. Runtime receives no app-registration administration privileges.

Prefer Exchange Online **Application RBAC**, assigning `Application Mail.Send`
only for a scope containing the five mailboxes. Do not additionally grant the
same principal unscoped Entra `Mail.Send`: those grants are additive and defeat
the RBAC boundary. Legacy Application Access Policy guidance is documented as
an alternative, not mixed into the default.

## 3. Fail-closed authorization and data handling

Single-tenant authority; validate MSAL OIDC results, tenant, object ID, and an
explicit object-ID allowlist or directly emitted group claim. Group overage
fails closed (no directory-wide group lookup). Operators upload, start mail,
cancel and retire runs; the five resolved demo object IDs can perform only their
assigned Teams actions. No auth bypass, including in local development.

## 4. Small ACI HTTPS deployment, without fictitious native ACI TLS

ACI has no managed native HTTPS ingress. A Caddy sidecar terminates TLS on
80/443 using Azure's assigned ACI FQDN, and proxies to the application on loopback
8000 (not exposed publicly). The noninteractive postprovision hook initializes
the same ACI group with a dormant app and HTTP-only Caddy 503, retrieves the actual
FQDN, and registers matching URLs in Entra. Final deployment starts the real app
and enables Caddy automatic public ACME issuance/renewal. No custom DNS or
preconfigured hostname is required. Public DNS resolution, inbound 80/443 and
successful CA validation remain prerequisites; failures are not bypassed.
The azd deploy hook creates or replaces the group using the manually published
images in `config/container-images.json`. It never builds or pushes images.
Compose extends that same JSON configuration, and smoke tests use it by default.
Provision creates supporting resources and the initial group, not a new registry.
Default images are pulled anonymously, including across tenants; no registry
credentials or AcrPull grant are needed. Managed-identity image pulls for private
same-tenant ACR are an explicit opt-in. There is no untrusted bootstrap image.
Prefer explicit release tags or
digests; the requested tagless app default uses Docker's implicit `latest`.
For enterprise deployments prefer Application Gateway/private ACI or another
managed ingress platform; the POC intentionally avoids their cost.

## 5. Temporary demo state, not distributed background scheduling

The default ACI demo uses separate `emptyDir` volumes for Caddy certificates and
the local execution journal, matching the simpler Odoo demo pattern. No Azure
storage accounts or private-network infrastructure are provisioned. The local
journal uses atomic JSON replacement and fsync; persistence errors poison it
and stop execution. One nonroot application process/replica is required.
The optional Blob backend is retained in code for custom deployments, not used
by default. The journal contains pending message content; reports and logs do
not. Retiring a run removes bodies but retains its fingerprint/tombstone.

An action is durably marked running before its HTTP request. On restart it becomes
unknown, never automatically retried, **if the journal survives**. ACI lifecycle
changes can erase temporary volumes, certificates and all replay records. The
operator explicitly accepted this demo-only tradeoff. Export reports before
changes and inspect remote outcomes before executing scenarios after state loss.
A Graph 202 means accepted, not delivered.
Retries are restricted to explicit HTTP 429 rejections; POST timeouts/5xx are
ambiguous and are not retried. Read-only user-resolution calls can retry 5xx.
Exactly-once delivery cannot be promised because Graph sendMail has no supported
idempotency-key guarantee. The journal prevents automatic replay, not remote
duplicates after an administrator deliberately creates a different scenario.

## 6. Explicit resource mapping and safe content

Team/channel aliases map to administrator-supplied IDs outside scenarios. This
avoids broad Teams discovery/read permissions. Graph itself checks channel access.
User placeholders use only `{{user.key.displayName}}` and
`{{user.key.userPrincipalName}}`, replaced literally, never through Jinja.
Email HTML is sanitized to a small formatting-only allowlist (no links/images).
All Teams bodies are plain text.

## Verified official contracts

- [sendMail v1.0](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
- [channel messages v1.0](https://learn.microsoft.com/en-us/graph/api/channel-post-messages?view=graph-rest-1.0)
- [channel replies v1.0](https://learn.microsoft.com/en-us/graph/api/chatmessage-post-replies?view=graph-rest-1.0)
- [Exchange Application RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)

No beta dependency. This is a security-conscious POC, not a certified production
bulk-mail product or a substitute for tenant-specific penetration testing.

The documented v1.0 application permission for listing/resolving users is
`User.Read.All`, not delegated `User.ReadBasic.All`. This directory read privilege
is needed solely for mandatory startup UPN resolution; only `id` and
`userPrincipalName` are selected. It does not grant mailbox-content read access.
See [list users](https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0).
