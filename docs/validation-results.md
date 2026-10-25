# Validation results

Local checks performed on 2026-10-25. No live Azure deployment, Entra sign-in,
Exchange scope assignment or Microsoft 365 message delivery is claimed.
Earlier sections record checks for earlier configurations; see the temporary
demo-storage follow-up below for the current deployment.

| Check | Actual result |
|---|---|
| Unit/integration suite, Windows Python 3.14 | 43 passed |
| Same suite, Linux Python 3.12 container | 43 passed |
| Ruff format and lint | Passed |
| mypy application source | Passed, 11 modules |
| Bandit application source | Passed; documented SafeLoader subclass and non-security backoff jitter suppressions only |
| pip-audit runtime hash lock | No known vulnerabilities reported |
| Primary/skill JSON Schema equality and validity | Passed |
| Default and skill sample validation | Passed, no Graph calls |
| Assisted Teams sample model/schema | Passed; live alias resolution requires administrator mapping |
| Skill frontmatter and embedded complete YAML example | Passed |
| High-confidence credential-pattern / repository contract checks | Passed; not proof that all possible credential formats are detected |
| Bicep main/foundation and ACI entrypoints | Compiled successfully without diagnostics |
| PowerShell administrator/deployment script syntax | All parsed successfully |
| azure.yaml | Validated against official azd project JSON Schema |
| azd CLI project parsing | Portable checksum-verified azd 1.37.1 `show --no-prompt --output json` succeeded; hook-driven project recognized |
| Compose | Rendered/validated; app has no published ports, only Caddy does |
| Multi-stage Python 3.12 production image | Built successfully |
| Original Caddy configuration | Validated with Caddy 2.11.7; see image-configuration follow-up below for the new default |
| Live image startup behind Caddy | Passed with injected no-write Graph test gateway |
| Actual TLS smoke | CA-chain and localhost hostname validation, HSTS, health JSON, landing HTML, stylesheet and HTTP 308 redirect passed |

## Important qualification

The TLS smoke uses a temporary Caddy local CA, explicitly supplied to Python's
SSL verification context. No `--insecure`/disabled hostname validation was used.
Windows Schannel curl initially could not obtain local-CA revocation status;
the final check used normal Python certificate-chain/hostname verification
instead. Temporary certificates and test containers were removed.

Starlette emits one upstream deprecation warning about its current httpx-based
TestClient. Tests pass on both runtimes; runtime Graph HTTP is unaffected.

## Not executed / administrator acceptance still required

- `azd up`, `azd down`, Azure resource provisioning and real endpoint readiness.
- Live single-tenant OIDC sign-in/consent, group claim policy and conditional access.
- Graph application-role grants and five-in-scope/sixth-out-of-scope Exchange tests.
- Real email acceptance/delivery and each user's Teams channel membership.
- Public DNS/ACME issuance/renewal and ACI image-pull/RBAC propagation.
- Temporary-volume behavior during live ACI lifecycle operations (local recovery is tested).
- Container OS/Caddy vulnerability advisory scan and live penetration testing.
- GitHub OIDC pipeline execution in an administrator-configured environment.

These require administrator-owned subscriptions, tenant resources or additional
release security tooling. Static success is not a claim of successful deployment.

## Intentional configuration placeholders

- `.env.example`: blank tenant/application/operator/credential settings, example
  local ACME email; copy to ignored `.env` and fill securely.
- `config/demo-users.yaml`: fictional contoso example UPNs; replace all five.
- `config/resources.yaml`: empty channel mapping plus commented ID templates.
- `README.md` / `docs/*.md`: angle-bracket IDs, example custom domains and
  administrator commands are documentation, not deployed values.
- `.github/workflows/azure-dev.yml`: GitHub environment variable references,
  requiring administrator configuration; no secret Azure credential placeholder.

Infrastructure templates use parameter/environment references, not real tenant
IDs or credentials. Valid scenario examples are deliberately dry-run-only.

## Image-configuration follow-up

The deployment now consumes manually published images from
`config/container-images.json`: app
`acrdefcontainer.azurecr.io/azd-m365-demo-loader` (implicit latest) and Caddy
`acrdefcontainer.azurecr.io/caddy:2.11.4-alpine`. No build/push or registry creation
is performed by deployment. Existing-registry pull authorization is a manual
administrator prerequisite.

- Windows regression suite: **45 passed** (including two shared-image config tests).
- Ruff formatting/lint and repository contract checks passed.
- Both Bicep entrypoints compiled, and PowerShell scripts passed syntax parsing.
- Actual Compose resolution selected both configured images, with no build
  directives and no public app port.
- Caddy **2.11.4-alpine** configuration validation and live certificate-chain /
  hostname, HSTS, health, HTML, CSS and HTTP-to-HTTPS smoke checks passed using
  the public upstream image as an explicit test override.
- No images were pushed, and no access to the private `acrdefcontainer` registry
  or Azure deployment was attempted. Its contents, pull permissions and network
  reachability remain administrator acceptance checks.

## Secretless ACI registration follow-up

Runtime web-client and local-mail secret paths were removed. MSAL now uses a
lazy assertion callback backed by ACI's user-assigned managed identity for
`api://AzureADTokenExchange/.default`. Direct app-only Graph calls continue to
use the managed identity's own Graph token and explicit runtime grants.

- **48 Python tests passed** on Windows and target Linux Python 3.12, including
  lazy assertions, assigned-identity selection and no secret/developer fallback.
- PowerShell 7 mocked registration tests passed: create, rerun without duplicates,
  callback/logout URL generation/update, FIC issuer/subject/audience,
  assignment-required enterprise principal, tenant rejection and explicit Graph
  authorization failure without interactive fallback.
- Ruff, mypy, Bandit and repository contract checks passed.
- Both Bicep entrypoints compiled; PowerShell scripts parsed successfully.
- Refreshed Python 3.12 hash lock removes unused azure-keyvault-secrets;
  pip-audit reported no known vulnerabilities.
- The updated production image built successfully.
- The rebuilt image passed Caddy 2.11.4 TLS-chain/hostname, HSTS, health,
  HTML/CSS and HTTP-to-HTTPS checks with the no-write mock gateway.

The noninteractive postprovision hook uses an already-authorized **deployment**
identity; it does not grant consent or users/groups access. These remain
administrator tasks as explicitly selected. It stores no credential and the
runtime has no app-registration management privilege.

These are mocked/offline checks, not claims of live Entra registration,
authorization-code redemption with federation, Azure deployment or user sign-in.
Those require the administrator's real tenant and permission bootstrap.

## Automatic ACI hostname follow-up

PUBLIC_HOSTNAME is now discovered, not required input. The postprovision hook
creates the configured ACI group in dormant initialization mode (or reuses an
existing group), reads Azure's actual `ipAddress.fqdn`, persists the HTTPS URL,
and registers matching Entra URLs/trust. Final deployment checks the completed
registration marker, starts the real app, enables Caddy ACME, and verifies both
TLS and the `ready` health payload. No custom domain/CNAME is required.

Validated locally:

- **48 Python tests passed**; repository contracts, Ruff formatting/lint passed.
- Both Bicep entrypoints compiled successfully.
- PowerShell 7 mocked integration tests passed for first-time safe bootstrap,
  actual-FQDN retrieval (distinct from the requested DNS label), URL persistence,
  Entra/Caddy/app agreement, reuse without resetting existing groups, hostname
  drift rejection, incomplete-registration rejection, and failure on HTTP 200
  with a non-ready payload.
- PowerShell syntax checks passed for the shared deployment helper and hooks.
- The actual bootstrap Caddy configuration extracted from compiled Bicep ran in
  Docker and returned only HTTP 503; it did not obtain/store certificates.

No Azure deployment or public `azurecontainer.io` ACME issuance has been
performed. Live issuance still requires working public DNS, reachable ports,
certificate-authority acceptance/rate-limit availability and writable persistent
certificate storage. Missing registry pull permissions can stop the initial hook:
grant them to the provisioned identity and rerun provision.

## Temporary demo-storage follow-up

The default ACI deployment now follows the referenced Odoo demo's `emptyDir`
pattern. It creates no Azure Storage accounts, shares, Blob containers or Blob
role assignments. Caddy and the app journal have separate temporary volumes.
The app explicitly disables its optional Blob backend. The configured Alpine
Caddy image initializes the journal directory as UID/GID 10001, mode 700, before
the nonroot app starts. Deployment logs and the UI warn about state loss.

Actual local checks:

- Both Bicep entrypoints compiled; compiled-template assertions verified no
  storage resources, no Azure Files mounts/storage parameters, isolated
  temporary volumes, initialization permissions, and only public ports 80/443.
- Linux PowerShell mocked registration/deployment and all nine prerequisite
  scenarios passed. All deployment scripts parsed.
- The updated production image built and passed the Caddy 2.11.4 TLS-chain/
  hostname, HSTS, health, HTML/CSS and HTTP redirect smoke checks.
- The smoke used the same journal permissions initializer and confirmed the
  nonroot application wrote its local journal onto the initialized volume.
- Repository contracts and whitespace checks passed.
- Python regression suite: **43 passed, 5 failed**. The same five failures were
  reproduced on unchanged HEAD in an isolated baseline worktree. They are
  existing fixture expectations for the configured image tag and user mappings,
  not regressions from temporary-storage changes. Configuration was not reverted
  or rewritten to make these checks pass; the baseline worktree was removed.

No live deployment, public ACME issuance or actual ACI volume-lifecycle behavior
was verified. Temporary state is not durable: stop/restart/update/recreation can
erase execution history and duplicate-send protection. Export reports and review
prior sends before executing scenarios after storage loss. Caddy may need to
obtain certificates again, subject to CA limits.

## Cloud Shell operator-input follow-up

The azd setup now accepts one operator GUID directly, without JSON on the command
line, as well as a JSON array for multiple operators. A shared validator runs in
preprovision and final/bootstrap deployment. The app still receives its required
JSON array through the ARM parameter file; malformed input is not silently
repaired or ignored.

- All **16** Linux PowerShell prerequisite scenarios passed, including plain
  GUID input, malformed JSON, non-GUID values, null, object, scalar JSON and
  non-string array members.
- Mocked orchestration verified exact single-element JSON-array serialization
  for bootstrap and a two-operator array for final deployment.
- PowerShell syntax and repository checks passed.
