# Threat model

Assets: demo mailbox/channel integrity, tenant identities, delegated and
application tokens, managed-identity federation trust, TLS private keys, scenario bodies and replay
records. Trust boundaries: browser -> Caddy -> FastAPI, Entra -> session,
uploaded YAML -> typed plan, app -> Graph, app -> durable Blob, sidecar -> TLS
storage, CI/deployer -> Azure control plane.

| Threat | Control | Residual risk / verification |
|---|---|---|
| Malicious YAML, alias bombs, unsafe tags, expressions | Bounded ASGI body before multipart parsing; extension/MIME checks; SafeLoader subclass; no aliases/tags/duplicate keys; JSON Schema and typed constraints; no eval/Jinja on content | Parser dependencies still require updates; tests cover hostile documents |
| Arbitrary/external email recipients, bulk-mail abuse | Logical keys only by default, To/Cc validation, 200 actions/run, 100 stored runs, operator-only upload/start, explicit real-send confirmation, rate/concurrency/batch limits, CDX confirmation | Authorized operator can misuse a demo account; monitor, keep external override false |
| Excessive Graph permissions | Separate runtime/web identities, directory read only for required startup resolution, no mailbox read, five-mailbox Exchange Application RBAC | Directory User.Read.All is tenant-wide; administrator must verify no additive broad Mail.Send grant |
| Token theft / cross-tenant login | Tenant-specific MSAL code flow, state/nonce, exact tenant/object checks, allowlists/direct group claims, memory-only tokens, opaque Secure HttpOnly SameSite cookie, CSP and CSRF | Browser compromise and memory compromise remain; shared ACI identity trust with Caddy |
| Group overage bypass | Fail closed; no group-lookup fallback | Large-group users need explicit operator ID or a small direct group |
| Secret leakage in logs/reports | No access logging, no raw Graph body/error logging, fixed error text, content-free report allowlist, redaction filter, library log levels | Unhandled third-party diagnostics must be reviewed before enabling verbose logs |
| Replay/duplicates, process crash | Scenario ID/fingerprint/tombstones, per-step keys, durable running-before-send journal, ETag writes, restart running -> unknown, no retry of ambiguous POST | Graph sendMail does not guarantee idempotency; exactly-once impossible; administrators can deliberately change IDs |
| CSRF, XSS, hostile origin/Host | CSRF token and origin checks, escaped Jinja output, literal placeholders, formatting-only email HTML sanitizer, strict headers and fixed public origin | Front-channel logout intentionally clears only local auth; cannot send mail |
| Exposing ACI directly | Only Caddy 80/443 public; application 8000 not published; custom DNS/ACME; HTTPS readiness check | Public ACI is not WAF/private ingress; use Application Gateway/private ACI for higher assurance |
| Compromised image / supply chain | Multi-stage nonroot app, hash-locked Python runtime, CI lint/tests/Bandit/pip-audit, private registry pull identity, centralized image references, explicit Caddy version, least-privilege deployment | Images are published manually; tagless app defaults to mutable latest. Prefer reviewed immutable digests. Base/Caddy OS packages need separate advisory review; all group containers share identity boundary |
| Persistent uploaded content | Private Entra Blob, encryption at rest, explicit retirement, no raw-journal web download, protected local disk | Journal backups contain bodies; operator must manage retention and keep fictional data |
| TLS private-key exposure | Separate private certificate-only Azure Files share; runtime app does not mount it; key obtained server-side by ARM | ACI Azure Files uses an account key; Azure control-plane admins can access it |
| Graph throttling / denial of service | 429 Retry-After budget, bounded backoff, call timeouts, semaphore, proxy-client request limiting, bounded sessions/uploads/batches | Global proxy-client limiter can affect several users; not a distributed internet DDoS defense |
| Accidental production tenant use | Explicit DEMO_TENANT_CONFIRMED, exact tenant authority, five-user startup resolution, delivery disabled by default, visible preview | No API can reliably prove "CDX"; administrator confirmation and tenant governance remain required |
| Configuration drift | Fingerprint binds planned users/resources/tenant/recipient policy to run | Changed plans require explicit review/new scenario; do not mutate stored journals |

## Required administrator acceptance checks

- Five scoped mailbox tests allow, sixth forbids; no additive grants.
- An unassigned/cross-tenant user cannot sign in. A demo user cannot upload,
  start mail or execute another user's Teams actions.
- Public port 8000 is unreachable; Caddy's public certificate verifies and HTTP
  redirects. Local CA is trusted explicitly, never by disabling TLS validation.
- Persist/restart during a test write produces unknown, not a replay.
- Reports/logs exclude bodies and credentials; retirement removes stored bodies.
- CI identity federation is environment-protected and not triggered from forks.

This document is a design threat analysis, not an assertion that live tenant
penetration testing, Azure policy certification or image-vulnerability scanning
has occurred. Consult [actual validation results](validation-results.md).
