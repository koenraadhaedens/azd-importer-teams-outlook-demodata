# Troubleshooting

| Symptom | Investigation / fix |
|---|---|
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
| Key Vault 403 | Verify managed identity Secrets User role and administrator Secrets Officer role separately; allow RBAC propagation. |
| Journal 503 | Stop competing instances; check Blob availability/ETag conflicts, account permissions and local disk. Restart after correcting cause, preserving journal. |
| HTTPS unavailable | Check public DNS CNAME, CAA records, port 80/443 reachability, Caddy ACME logs and certificate-share mount. ACI has no native managed TLS. |
| HTTPS works but app 502 | Check startup/config/consent failures in application logs; Caddy is only a reverse proxy, not readiness proof. |
| ACI image pull fails | Confirm both images in config/container-images.json were manually pushed. Grant the runtime managed identity AcrPull on each standard RBAC registry (repository-reader access for ABAC registries), allow propagation and check registry networking. No registry password or automatic push is supplied. |
| Source/configuration update not visible | Manually rebuild/push the app with its packaged user/resource files and update the configured release tag/digest. The deployment pipeline does not build images. Do not rely on overwriting an unchanged latest reference to refresh ACI. |
| Localhost certificate warning | Caddy uses local CA; explicitly trust its root for test use. Do not use --insecure in ordinary operation. |
| DNS label changed / deployment not ready | Read actual ACI FQDN from deployment/CLI and update CNAME. Rerun azd deploy after propagation. |
| azd reports no native services | Intentional: ACI uses predeploy hook. Use current azd and PowerShell 7; hooks must not be skipped. |
| Azure CLI login absent despite azd login | Run az login too, or azure/login OIDC in CI. Hooks deliberately use Azure CLI. |
| Key Vault name cannot be reused after down | Purge protection/soft deletion is intentional; recover or wait, do not weaken protection. |

Never paste access tokens, authorization callback URLs, passwords, client secrets
or raw journal content into an issue. Provide a redacted report/correlation ID.
