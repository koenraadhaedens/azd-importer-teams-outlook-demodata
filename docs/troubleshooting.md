# Troubleshooting

| Symptom | Investigation / fix |
|---|---|
| Missing azd environment value: OPERATOR_IDS or ACME_EMAIL | Run the [single-command setup](../installtocloudshell.md#2-run-setup), or retry setup.ps1 -Stage Provision -ConfirmDemoTenant after preparing the private file. It resolves the operator and saves the file path; hooks read certificate email privately. For manual setup, set DEMO_CONFIG_FILE to the absolute private file path and OPERATOR_IDS to an allowed Entra user object ID (or JSON array). Do not put trainer email in the tracked template or azd command arguments. |
| Private configuration missing or invalid at startup/deployment | Run the Configure stage or restore the ignored local file. Deployment injects x-demo using DEMO_CONFIG_JSON; an invalid injected value fails closed without falling back to a file. Older images need a one-time rebuild to support injection. Never paste the private JSON into support logs. |
| OPERATOR_IDS ConvertFrom-Json / invalid-number error | JSON quotes may have been lost when passed through native commands. For one operator, use azd env set OPERATOR_IDS <your-user-object-id> without JSON brackets. Hooks accept the GUID directly and serialize a JSON array into the ARM parameter file. Invalid JSON, non-array JSON and non-GUID IDs fail validation before provisioning. |
| Cloud Shell preprovision reports Bicep CLI not found | The current hook installs missing Bicep with az bicep install. On an older checkout, run that command manually and retry azd provision. Installation needs download access and a writable Azure CLI configuration directory. A failed install or verification stops provisioning explicitly; check bicep.use_binary_from_path if an installed binary is not found. |
| Postprovision tenant check fails | Provisioning exports AZURE_TENANT_ID from the selected subscription. Older checkouts may leave it empty and report a misleading authentication error. Compare azd env get-value AZURE_TENANT_ID with az account show --subscription <selected-subscription-id> --query tenantId -o tsv. After verifying this is the isolated CDX tenant, save a missing value with azd env set AZURE_TENANT_ID <verified-tenant-id> and rerun azd provision. For an actual mismatch, correct the selected subscription/login; do not bypass the tenant check. |
| Startup refuses tenant/operator configuration | Fill tenant/web IDs; confirm isolated CDX explicitly; configure operator IDs or a direct security group. No auth bypass exists. |
| User resolution 403 | Postprovision assigns Graph application User.Read.All to the verified runtime principal. Confirm the hook reported assigned/already assigned, then allow permission/token-cache propagation. If missing, run azd provision with an identity authorized to grant this role. Managed identity alone is insufficient; do not grant broader directory/mail permissions to bypass the error. |
| A configured UPN is not found | Replace sample UPNs with real CDX users, verify tenant and license, check exact UPN rather than SMTP alias. |
| New-ManagementScope says an existing scope has the same filter, or New-ManagementRoleAssignment says the scope was not found | Older helpers can keep using a proposed new name after equivalent scope creation fails. Update setup-exchange.ps1 in the deployment checkout and follow the [recovery commands](#recovering-from-an-existing-exchange-scope-after-a-fresh-deployment). The current helper reuses an exact five-address scope, uses its actual name and gives each runtime identity its own verified assignment. It never changes an existing scope; ambiguity or a conflicting principal/assignment fails explicitly. Verify five allowed mailboxes and one excluded mailbox before setting MAILBOX_SCOPE_CONFIRMED=true. No container rebuild or redeployment is needed for the Exchange grant. |
| New environment seems to reuse an old app or mail scope | Azure resource-group deletion does not delete Entra registrations/enterprise applications or Exchange registrations/scopes/assignments. Select the intended azd environment and reload WEB_CLIENT_ID, AZURE_IDENTITY_CLIENT_ID and AZURE_IDENTITY_PRINCIPAL_ID rather than reusing shell variables. The web app ID is separate from the runtime identity used for Exchange; an existing mailbox scope is not proof of web app reuse or a grant to the new identity. |
| Mail 403 | Verify Exchange service-principal object ID, five-mailbox scope, Application Mail.Send assignment and propagation. Do not "fix" it by granting broad Mail.ReadWrite. |
| Mail succeeds outside five users | Stop delivery immediately; inspect additive Entra Mail.Send and other Exchange role assignments. Application checks are not a substitute for mailbox scope. |
| Teams 401/403 | Sign in again as assigned author; confirm delegated consent, enterprise assignment, license and channel membership. Cannot use managed identity/migration permission for normal posts. |
| Teams button absent | Operator must start a non-dry-run scenario; reload after start and sign in as one of the five demo authors. |
| Pending action does not run | Check dependency outcomes, delay and background worker state on the run page/report. Each Teams author must sign in and authorize their background messages once for that run. Authorized workers and the email worker automatically wait across dependencies. For reauthentication_required, sign in and resume the same run; for failed, inspect sanitized application logs and permissions. If upgrading, update reviewed consent to include offline_access and sign in again. Closing a browser does not stop work; explicit logout revokes that session's future Teams sends. App/container restart requires operator resumption and author authorization again. |
| Duplicate scenario rejected | Open its existing run; no replay endpoint. Review uncertain remote outcomes before making a deliberately new scenario. |
| Run blocked after config change | Restore reviewed mappings or create a separately reviewed new scenario; existing configuration fingerprint is immutable. |
| Unknown step | Request/process may have ended after Graph accepted it. Inspect mailbox/channel manually. Do not retry blindly. |
| File rejected by MIME | Save as UTF-8 .yaml/.yml and send one of the documented MIME types. Browsers may label YAML as application/octet-stream; current images accept this with full content validation. Rebuild/push and deploy the updated image if an older image rejects it. |
| Upload returns Invalid request origin | This happens before YAML validation. Older images send Referrer-Policy: no-referrer, which makes browser form submissions send Origin: null. Rebuild/push and deploy the fixed app image, which uses same-origin, then reload the form before retrying. Also ensure the browser origin matches PUBLIC_URL exactly (including https:// and any port). Do not disable CSRF/origin checks or allow the null origin. |
| 413 / 429 | Reduce file size or wait for the one-minute request window; do not remove bounds to bypass abuse protection. |
| Session lost / group overage | Restart loses memory sessions; sign in again. Use explicit allowed object IDs or a small directly emitted group. |
| Federation/token exchange fails | Verify the web app's aci-managed-identity credential: same tenant, issuer ending /v2.0, subject equal to the identity principal ID (not client ID), audience api://AzureADTokenExchange. Allow propagation. No web secret or vault access is required. |
| Registration/runtime-role hook 403 | Pre-authorize the separate deployment identity for Graph application management and AppRoleAssignment.ReadWrite.All. A signed-in administrator also needs the Entra role required for Microsoft Graph app-role grants. Azure subscription Owner is insufficient. The hook will not prompt, elevate itself or silently skip setup. |
| Journal 503 | Run one process/replica and check local journal volume permissions/disk space. The initializer must set UID/GID 10001 and directory mode 700. Correct the cause while preserving any surviving journal; do not reset it to bypass duplicate detection. |
| HTTPS unavailable | Check Azure's assigned FQDN resolves, ports 80/443 and Caddy ACME logs/CA rate limits. Temporary-volume loss forces certificate reissuance. Do not disable certificate verification. ACI has no native managed TLS. |
| HTTPS works but app 502 | Check startup/config/consent failures in application logs; Caddy is only a reverse proxy, not readiness proof. |
| ACI image pull fails | Confirm both image/tag references in config/config.json were published and are anonymously pullable. Leave USE_MANAGED_IDENTITY_FOR_IMAGE_PULL unset or false for public images, including registries in another tenant. Check registry networking and image/platform compatibility. Only for opt-in private same-tenant ACR pulls, grant the runtime identity AcrPull (repository-reader access for ABAC registries) and allow propagation. No registry password or automatic push is supplied. |
| InaccessibleImage for a public repository, or only a generic deployment error is visible | Public access does not guarantee the requested tag exists. Pushing :latest does not publish a separately configured release tag. Retrieve the recorded deployment error and follow the [exact-tag build/push instructions](../installtocloudshell.md#updating-an-existing-deployment). Publish the exact app reference from config/config.json before retrying; do not add credentials to fix a missing tag. USE_MANAGED_IDENTITY_FOR_IMAGE_PULL being absent from azd values is expected for anonymous pulls. |
| Source/configuration update not visible | Source changes require a manually rebuilt/published image and a new release tag/digest. User/channel/email changes require redeployment from the private local file, not a rebuild; review grants when changing users. The pipeline does not build images. Do not overwrite an unchanged latest reference and assume ACI will refresh it. |
| Localhost certificate warning | Caddy uses local CA; explicitly trust its root for test use. Do not use --insecure in ordinary operation. |
| ACI hostname changed | Run azd provision to rediscover ipAddress.fqdn and update saved URLs/Entra, then azd deploy. No manual CNAME is needed. |
| HTTP 503 initialization response | Expected before final deployment: the app is dormant and Caddy has not requested a certificate. Complete registration/admin grants then run azd deploy. A bootstrap group is not application readiness. |
| azd reports no native services | Intentional: ACI uses predeploy hook. Use current azd and PowerShell 7; hooks must not be skipped. |
| Azure CLI login absent despite azd login | Run az login too, or azure/login OIDC in CI. Hooks deliberately use Azure CLI. |
| Old Key Vault or Log Analytics workspace remains after provisioning | Current templates no longer provision either resource or configure workspace diagnostics. Incremental ARM deployments do not delete resources removed from templates. Review and remove unused legacy resources separately after preserving required secrets/logs. Legacy Key Vault soft deletion/purge protection can prevent immediate name reuse; do not weaken protection. Current deployments do not need a vault name. |

Never paste access tokens, authorization callback URLs, passwords, client secrets
or raw journal content into an issue. Provide a redacted report/correlation ID.

## Recovering from an existing Exchange scope after a fresh deployment

Deleting an Azure resource group or running `azd down` does not delete tenant-level
Entra apps, Exchange registrations, scopes, or role assignments.
The helper reuses a scope with exactly the same five primary SMTP predicates,
regardless of order, case or parentheses. Each runtime identity gets its own
`DemoMailSend-<principal-object-id>` assignment.

For older-helper errors, update the checkout, select the intended environment
with `azd env list` / `azd env select <name>`, and retry:

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Exchange -InstallModules
```

The helper prints the resolved scope name and tests all six mailboxes.
Do not retry with a guessed scope name. Multiple equivalent scopes or conflicting
principals/assignments require manual review. For an explicitly reviewed scope,
use [setup-exchange.ps1](../scripts/setup-exchange.ps1) with `-ScopeName` and the
selected environment's runtime identity IDs. `WEB_CLIENT_ID` is the web app,
not the Exchange runtime identity. Do not remove old grants until confirmed retired.
