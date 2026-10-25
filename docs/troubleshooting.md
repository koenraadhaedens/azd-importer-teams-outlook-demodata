# Troubleshooting

| Symptom | Investigation / fix |
|---|---|
| Cloud Shell preprovision reports Bicep CLI not found | The current hook installs missing Bicep with az bicep install. On an older checkout, run that command manually and retry azd provision. Installation needs download access and a writable Azure CLI configuration directory. A failed install or verification stops provisioning explicitly; check bicep.use_binary_from_path if an installed binary is not found. |
| Postprovision tenant check fails | Provisioning exports AZURE_TENANT_ID from the selected subscription. Older checkouts may leave it empty and report a misleading authentication error. Compare azd env get-value AZURE_TENANT_ID with az account show --subscription <selected-subscription-id> --query tenantId -o tsv. After verifying this is the isolated CDX tenant, save a missing value with azd env set AZURE_TENANT_ID <verified-tenant-id> and rerun azd provision. For an actual mismatch, correct the selected subscription/login; do not bypass the tenant check. |
| Startup refuses tenant/operator configuration | Fill tenant/web IDs; confirm isolated CDX explicitly; configure operator IDs or a direct security group. No auth bypass exists. |
| User resolution 403 | Explicitly assign Graph application User.Read.All to the **runtime** principal; managed identity alone is insufficient. Allow consent propagation. |
| A configured UPN is not found | Replace sample UPNs with real CDX users, verify tenant and license, check exact UPN rather than SMTP alias. |
| Mail 403 | Verify Exchange service-principal object ID, five-mailbox scope, Application Mail.Send assignment and propagation. Do not "fix" it by granting broad Mail.ReadWrite. |
| Mail succeeds outside five users | Stop delivery immediately; inspect additive Entra Mail.Send and other Exchange role assignments. Application checks are not a substitute for mailbox scope. |
| Teams 401/403 | Sign in again as assigned author; confirm delegated consent, enterprise assignment, license and channel membership. Cannot use managed identity/migration permission for normal posts. |
| Teams button absent | Operator must start a non-dry-run scenario; reload after start and sign in as one of the five demo authors. |
| Pending action does not run | Check earlier dependencies, delay and assigned author; click that user's batch again or have operator resume email. No cross-user unattended scheduler is provided. |
| Duplicate scenario rejected | Open its existing run; no replay endpoint. Review uncertain remote outcomes before making a deliberately new scenario. |
| Run blocked after config change | Restore reviewed mappings or create a separately reviewed new scenario; existing configuration fingerprint is immutable. |
| Unknown step | Request/process may have ended after Graph accepted it. Inspect mailbox/channel manually. Do not retry blindly. |
| File rejected by MIME | Save as UTF-8 .yaml/.yml and send one of the documented YAML/text MIME types; octet-stream is not accepted. |
| 413 / 429 | Reduce file size or wait for the one-minute request window; do not remove bounds to bypass abuse protection. |
| Session lost / group overage | Restart loses memory sessions; sign in again. Use explicit allowed object IDs or a small directly emitted group. |
| Federation/token exchange fails | Verify the web app's aci-managed-identity credential: same tenant, issuer ending /v2.0, subject equal to the identity principal ID (not client ID), audience api://AzureADTokenExchange. Allow propagation. No web secret or vault access is required. |
| Registration hook 403 | Pre-authorize the separate deployment identity for Graph application management; Azure subscription Owner is insufficient. The hook will not prompt for login/consent or silently skip setup. |
| Journal 503 | Stop competing instances; check Blob availability/ETag conflicts, account permissions and local disk. Restart after correcting cause, preserving journal. |
| HTTPS unavailable | Check Azure's assigned FQDN resolves, ports 80/443, Caddy ACME logs/CA rate limits and certificate-share mount. Do not disable certificate verification. ACI has no native managed TLS. |
| HTTPS works but app 502 | Check startup/config/consent failures in application logs; Caddy is only a reverse proxy, not readiness proof. |
| ACI image pull fails | Confirm both images in config/container-images.json were manually pushed. Grant the runtime managed identity AcrPull on each standard RBAC registry (repository-reader access for ABAC registries), allow propagation and check registry networking. No registry password or automatic push is supplied. |
| Source/configuration update not visible | Manually rebuild/push the app with its packaged user/resource files and update the configured release tag/digest. The deployment pipeline does not build images. Do not rely on overwriting an unchanged latest reference to refresh ACI. |
| Localhost certificate warning | Caddy uses local CA; explicitly trust its root for test use. Do not use --insecure in ordinary operation. |
| ACI hostname changed | Run azd provision to rediscover ipAddress.fqdn and update saved URLs/Entra, then azd deploy. No manual CNAME is needed. |
| HTTP 503 initialization response | Expected before final deployment: the app is dormant and Caddy has not requested a certificate. Complete registration/admin grants then run azd deploy. A bootstrap group is not application readiness. |
| azd reports no native services | Intentional: ACI uses predeploy hook. Use current azd and PowerShell 7; hooks must not be skipped. |
| Azure CLI login absent despite azd login | Run az login too, or azure/login OIDC in CI. Hooks deliberately use Azure CLI. |
| Key Vault name cannot be reused after down | Purge protection/soft deletion is intentional; recover or wait, do not weaken protection. |

Never paste access tokens, authorization callback URLs, passwords, client secrets
or raw journal content into an issue. Provide a redacted report/correlation ID.
