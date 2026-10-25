# Implementation plan

Repository/application name: **azd-m365-demo-loader**. The existing Git repository
name is retained; no remote or history is rewritten.

1. Verify Graph v1.0 permission and authentication contracts against Microsoft
   documentation. Record design decisions before implementing.
2. Implement strict five-user configuration, a versioned Pydantic/JSON Schema
   scenario contract, safe bounded YAML parsing, resource mappings and previews.
3. Implement single-tenant Entra authorization-code sign-in, server-side sessions,
   CSRF, explicit operator/user authorization, and delegated Teams token handling.
   Azure ACI runtime uses its user-assigned managed identity as a federated web
   app client assertion, not a local/Key Vault client secret. The noninteractive
   azd postprovision hook initializes a dormant ACI group, retrieves its actual
   FQDN and registers matching URLs/app/trust. Final deployment enables the app
   and Caddy ACME; no up-front hostname/custom DNS. Consent and assignments
   remain administrator-controlled.
4. Implement Graph adapters and an atomic execution journal: assisted Teams,
   app-only mail, cancellation, dependencies, bounded timing, safe retries,
   duplicate protection, dry-run and redacted reports.
5. Build the accessible server-rendered UI and tests of trust boundaries.
6. Add a multi-stage container, ACI deployment with a Caddy TLS sidecar, Key Vault,
   managed identity, temporary ACI certificate/journal volumes, azd hooks and OIDC CI.
   State and replay protection can be lost on ACI lifecycle changes; this is an
   explicitly accepted demo-only tradeoff. Per the updated
   image-publishing requirement, use manually published images in an existing
   registry configured through config/container-images.json; do not create a
   new registry or build/push during deployment.
7. Add administrator scripts, deployment/operations/security documentation,
   valid and invalid examples, and the portable Cowork scenario-creation skill.
8. Run formatting, lint, typing, unit/integration tests, schema/example validation,
   dependency/static security checks, Docker and Bicep checks where available.
   Record actual results and unavailable external prerequisites, never fabricated
   Azure deployment or tenant execution success.

## Acceptance and operating boundary

One container group, one application process, at most 200 activities per scenario,
exactly five configured users. Default outbound delivery is disabled until an
administrator explicitly confirms the isolated demo tenant and mailbox scope.
No demo-user passwords, migration permissions, beta Graph APIs, or local auth bypass.
Deployment and real Graph execution require administrator-owned tenant resources.
