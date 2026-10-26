# Threat model

Assets: demo mailbox/channel integrity, tenant identities, delegated and
application tokens, managed-identity federation trust, TLS private keys, scenario bodies and replay
records. Trust boundaries: browser -> Caddy -> FastAPI, Entra -> session,
uploaded YAML -> typed plan, app -> Graph, app -> temporary journal, sidecar -> TLS
storage, CI/deployer -> Azure control plane.

| Threat | Control | Residual risk / verification |
|---|---|---|
| Malicious YAML, alias bombs, unsafe tags, expressions | Bounded ASGI body before multipart parsing; extension/MIME checks; SafeLoader subclass; no aliases/tags/duplicate keys; JSON Schema and typed constraints; no eval/Jinja on content | Parser dependencies still require updates; tests cover hostile documents |
| Arbitrary/external email recipients, bulk-mail abuse | Logical keys only by default, To/Cc validation, 200 actions/run, 100 stored runs, operator-only upload/start, explicit real-send confirmation, rate/concurrency/batch limits, CDX confirmation | Authorized operator can misuse a demo account; monitor, keep external override false |
| Excessive Graph permissions | Separate runtime/web identities, directory read only for required startup resolution, no mailbox read, five-mailbox Exchange Application RBAC | Directory User.Read.All is tenant-wide; administrator must verify no additive broad Mail.Send grant |
| Token theft / cross-tenant login | Tenant-specific MSAL code flow, state/nonce, exact tenant/object checks, allowlists/direct group claims, memory-only access/refresh tokens, opaque Secure HttpOnly SameSite cookie, CSP and CSRF | Explicitly authorized background workers retain refresh capability beyond cookie expiry until completion/pause/cancellation; logout revokes that session's future sends. Browser/memory compromise and shared ACI identity trust with Caddy remain |
| Group overage bypass | Fail closed; no group-lookup fallback | Large-group users need explicit operator ID or a small direct group |
| Secret leakage in logs/reports | No access logging, no raw Graph body/error logging, fixed error text, content-free report allowlist, redaction filter, library log levels | Unhandled third-party diagnostics must be reviewed before enabling verbose logs |
| Replay/duplicates, process crash | Scenario ID/fingerprint/tombstones, per-step keys, atomic running-before-send journal, restart running -> unknown while the journal survives, no retry of ambiguous POST | ACI lifecycle changes can erase the temporary journal and all replay records. Review prior sends after loss. Graph sendMail does not guarantee idempotency; exactly-once impossible |
| CSRF, XSS, hostile origin/Host | CSRF token and origin checks, escaped Jinja output, literal placeholders, formatting-only email HTML sanitizer, strict headers and fixed public origin | Front-channel logout intentionally clears only local auth; cannot send mail |
| Exposing ACI directly | Only Caddy 80/443 public; application 8000 not published; Azure-assigned FQDN with Caddy ACME and verified HTTPS readiness; initialization serves only 503 with dormant app | Public ACI is not WAF/private ingress; use Application Gateway/private ACI for higher assurance |
| Compromised image / supply chain | Multi-stage nonroot app, hash-locked Python runtime, CI lint/tests/Bandit/pip-audit, centralized image references, explicit Caddy version, least-privilege deployment | Default anonymous images are public; do not package secrets or sensitive data. Images are published manually; prefer reviewed immutable digests. Base/Caddy OS packages need separate advisory review; all group containers share identity boundary |
| Uploaded content | Separate temporary journal volume, nonroot UID/GID 10001 and directory mode 700, explicit retirement, no raw-journal web download | Journal backups contain bodies; operator must manage retention and keep fictional data. Temporary volume loss also removes replay evidence |
| TLS private-key exposure | Separate temporary Caddy volume; runtime app does not mount it; no Azure storage account key | Control-plane administrators can access container data. State loss forces certificate reissuance and can hit CA rate limits |
| Graph throttling / denial of service | 429 Retry-After budget, bounded backoff, call timeouts, semaphore, proxy-client request limiting, bounded sessions/uploads/batches | Global proxy-client limiter can affect several users; not a distributed internet DDoS defense |
| Accidental production tenant use | Explicit DEMO_TENANT_CONFIRMED, exact tenant authority, five-user startup resolution, delivery disabled by default, visible preview | No API can reliably prove "CDX"; administrator confirmation and tenant governance remain required |
| Configuration drift | Fingerprint binds planned users/resources/tenant/recipient policy to run | Changed plans require explicit review/new scenario; do not mutate stored journals |

## Required administrator acceptance checks

- Five scoped mailbox tests allow, sixth forbids; no additive grants.
- An unassigned/cross-tenant user cannot sign in. A demo user cannot upload,
  start mail or execute another user's Teams actions.
- Public port 8000 is unreachable; Caddy's public certificate verifies and HTTP
  redirects. Local CA is trusted explicitly, never by disabling TLS validation.
- A process crash with surviving journal marks interrupted writes unknown.
  After temporary-volume loss, manually review prior sends before any execution;
  duplicate protection cannot recognize forgotten runs.
- Reports/logs exclude bodies and credentials; retirement removes stored bodies.
- CI identity federation is environment-protected and not triggered from forks.

This document is a design threat analysis, not an assertion that live tenant
penetration testing, Azure policy certification or image-vulnerability scanning
has occurred. Consult [actual validation results](validation-results.md).
