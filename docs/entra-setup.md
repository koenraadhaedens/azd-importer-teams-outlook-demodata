# Entra administrator setup

Two identities are intentional: the confidential interactive web app and the
runtime mail/directory principal (managed identity in Azure; separate app locally).

## Web app script

Use PowerShell 7 and install the Microsoft.Graph.Applications and
Microsoft.Graph.Identity.SignIns modules in your administrator environment.
The script does not install modules, mint secrets or silently grant consent.
Run in the intended CDX tenant; inspect `Get-MgContext` before making changes.

```powershell
pwsh .\scripts\setup-entra.ps1 `
  -PublicUrl https://your-controlled-hostname.example `
  -AllowedObjectIds @("<operator-object-id>", "<demo1-object-id>", "<demo2-object-id>", `
    "<demo3-object-id>", "<demo4-object-id>", "<demo5-object-id>") `
  -GrantConsent
```

The dedicated display name must resolve uniquely. Reruns update the registration,
add missing assignments and ensure delegated consent without duplicating them.
Existing unrelated assignments are not removed automatically; audit them.
If granting group access, assign the intended security group to the enterprise
app and configure AUTHORIZED_GROUP_ID. Group-based enterprise-app assignment may
require appropriate Entra licensing. Group overage fails closed; prefer explicit
operator IDs for this small POC.

### Manual fallback

1. Entra admin center > App registrations > New registration, single tenant,
   confidential **Web** platform (not SPA/public client).
2. Add exact callback `https://<host>/auth/callback`. For local direct HTTP only,
   add `http://localhost:8000/auth/callback`. Register only origins actually used.
   The script manages one origin; add additional redirect URIs manually afterward
   or rerun with the final deployment origin.
3. Disable implicit grants and public-client flows. Add delegated Microsoft Graph
   `ChannelMessage.Send`; grant administrator-reviewed consent.
4. Configure security-group claims if using an allowed group; do not add broad
   Graph membership-read permissions. Overage is intentionally rejected.
5. Enterprise application > Properties > Assignment required = Yes. Assign each
   demo user and operator or explicit allowed group. App-level OPERATOR_IDS/group
   still controls operator privileges; enterprise assignment alone is insufficient.
6. Create a short-lived web app credential through the secure portal and store
   it in Key Vault as `web-client-secret`. For local development only, put it in
   ignored `.env`. Rotate before expiration; never print it in script output,
   pass it via build arguments or store it in GitHub/Azure deployment variables.
7. Set runtime WEB_CLIENT_ID and tenant origin/configuration.

## Logout and session behavior

Front-channel logout URL: `https://<host>/auth/signed-out`. This performs
best-effort local session deletion when the browser supplies the session cookie.
Browser third-party-cookie blocking can prevent front-channel invalidation;
sessions expire in at most one hour regardless. Explicit local sign-out uses
CSRF-protected POST `/logout`, clears server-side token cache and redirects to
the tenant logout endpoint with `post_logout_redirect_uri=https://<host>/`.
Register that origin and use the web home page accordingly. No uploaded content
controls redirect or logout URLs.

MSAL authorization-code flow validates state/nonce and ID-token identity using
tenant-specific authority. Successful sign-in additionally checks exact `tid`,
`oid` and the operator/demo-user authorization boundary. Cookie contains only
an opaque session ID: HttpOnly, SameSite=Lax, Secure except documented localhost.
OAuth flow state and delegated tokens remain server-side. Session IDs rotate
after login. No refresh/offline token persistence; restart requires sign-in again.

## Runtime application/managed identity

After `azd provision`, take AZURE_IDENTITY_CLIENT_ID and
AZURE_IDENTITY_PRINCIPAL_ID from outputs. Run
[grant-graph-identity.ps1](../scripts/grant-graph-identity.ps1) with the principal
object ID and [setup-exchange.ps1](../scripts/setup-exchange.ps1) with both IDs.
Administrator consent/role grants are explicit and auditable.

For local use create a **separate** single-tenant confidential app/service
principal; assign application User.Read.All, apply the same Exchange scope,
and provide its credential only in the local ignored environment.

Azure Key Vault permissions: runtime identity receives Secrets User from Bicep;
the credential administrator separately needs Secrets Officer to write/rotate.
The deployer is not implicitly allowed to read/write web credentials.

## Revocation

Disable enterprise sign-in/assignments first. Revoke delegated grants under
Enterprise applications > Permissions; remove the runtime Graph app-role
assignment, Exchange application-role assignment and Exchange service-principal
pointer. Remove the credential, then delete the dedicated app registration and
enterprise application if no longer used. Managed identity is removed by resource
group teardown, but verify Exchange pointers/assignments are cleaned up.
Do not remove shared administrator identities or unrelated grants.
