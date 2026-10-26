# Entra setup: secretless Azure ACI

The deployment target is Azure Container Instances. There is no local
client-secret authentication mode. Two identities still have different purposes:

- **Web app registration:** interactive OIDC sign-in and delegated
  `ChannelMessage.Send`, authenticated using the container's managed identity
  as a federated client assertion rather than a password/certificate.
- **ACI user-assigned managed identity:** direct runtime Graph/Exchange access
  and proof of identity to the web app. Private same-tenant registry pulls can
  optionally use it; default image pulls are anonymous.

The app registration is still required: a managed identity by itself does not
provide a web redirect URI or delegated user sign-in.

## Automatic registration during azd provisioning

[azure.yaml](../azure.yaml) invokes
[initialize-web-endpoint.ps1](../scripts/initialize-web-endpoint.ps1) as a
**noninteractive postprovision hook**, after the supporting resources exist.
There is **no manual PUBLIC_HOSTNAME or custom DNS prerequisite**. The hook:

1. Verifies the provisioned runtime identity/tenant and automatically assigns
   Microsoft Graph application `User.Read.All` using the deployment identity's
   existing Azure CLI session. It checks all assignment pages and reuses an
   existing grant. Authorization failure stops postprovision before ACI startup.
2. Creates the ACI group in initialization mode if it does not already exist:
   the app is dormant, delivery is disabled, and Caddy returns HTTP 503 without
   requesting a certificate. Both manually published images must be anonymously
   pullable by default. Existing groups are not reset on reruns.
3. Retrieves **ipAddress.fqdn** from Azure (never guesses from the DNS label),
   saves PUBLIC_HOSTNAME/PUBLIC_URL, then invokes
   [register-web-app.ps1](../scripts/register-web-app.ps1). That script checks the
   CLI/managed-identity tenant and creates/updates a dedicated web registration.
4. Derives URLs from the retrieved `https://<ACI-FQDN>`:
   - redirect: `/auth/callback`
   - home/post-logout return: `/`
   - front-channel logout: `/auth/signed-out`
5. Requests delegated `ChannelMessage.Send` in the registration manifest.
   **Requesting a permission does not grant consent.**
6. Creates/updates a federated identity credential:
   - issuer: `https://login.microsoftonline.com/<tenant-id>/v2.0`
   - subject: managed identity **principal/object ID**, not client ID
   - audience: `api://AzureADTokenExchange`
7. Creates the enterprise service principal with assignment required.
8. Persists WEB_CLIENT_ID, WEB_APPLICATION_OBJECT_ID and
   WEB_SERVICE_PRINCIPAL_ID with `azd env set`. Only after successful registration
   does it save WEB_REGISTERED_HOSTNAME. The deploy hook explicitly reads
   the saved client ID/hostname, including within the same `azd up`. It applies
   the final app/Caddy configuration to the same group, explicitly starts the
   real app, and verifies the certificate and application health. A discovered
   hostname without a matching completed-registration marker cannot start the
   final app. Caddy obtains
   and renews the public certificate automatically via ACME.

It creates **no client secret or certificate**, grants **no delegated Teams
consent or mail permission**, and makes **no user/group assignments**. The one
automatic runtime permission grant is `User.Read.All`; setup privileges are
never granted to the runtime identity. Reruns reuse the saved client ID or uniquely named application and
update URLs/trust without duplicate registrations. Run provisioning serially;
the Graph create API is not a distributed uniqueness transaction.

### Deployment identity prerequisites

The Azure CLI must already be authenticated in the CDX tenant. The hook uses
`az rest` under that identity; it never calls `az login`, `Connect-MgGraph`,
device-code flow or a consent prompt. Azure subscription Owner alone does not
grant Entra application-management rights.

For unattended OIDC CI, an administrator must pre-authorize the **separate
deployment identity** for the Graph application-management operations. The
straightforward supported setup uses application `Application.ReadWrite.All`
for registration plus `AppRoleAssignment.ReadWrite.All` for the runtime Graph
role grant, with administrator consent. The former covers the application-read
permission needed for role discovery. These are powerful: restrict them to the protected deployment
environment and consider a tenant-admin-designed owned-app/custom-role setup if
you need tighter provisioning scope. That alternative must cover application
discovery, app/SP creation and updates, scope lookup, FIC management and the
runtime app-role assignment.

For a signed-in administrator's CLI, the authenticated account and CLI Graph
authorization must permit these operations under tenant policy. Granting Microsoft
Graph application roles also requires an appropriate Entra role, such as an
active Privileged Role Administrator role. Azure subscription Owner is not
equivalent. If permission
is missing the hook fails; it does not request interactive elevation.
**Never grant these setup privileges to the ACI runtime identity.**

## First-time sequence

```powershell
azd auth login
az login
azd env new my-demo-loader
# Configure ACME_EMAIL and other settings from README; do not set hostname/secret.
azd provision
azd env get-value WEB_CLIENT_ID
azd env get-value PUBLIC_URL
```

Now an administrator must:

1. Grant tenant-admin-reviewed delegated `ChannelMessage.Send` consent.
2. Assign the operator(s) and five demo users, or explicit permitted security
   groups, to the enterprise app. Keep assignment required = Yes.
3. Configure OPERATOR_IDS or AUTHORIZED_GROUP_ID separately for application
   operator privileges; enterprise assignment is not an operator grant.
4. Verify postprovision reported runtime `User.Read.All` assigned/already
   assigned, then configure the five-mailbox Exchange `Application Mail.Send`
   scope separately. Federation alone does not grant Graph or mail permissions.
5. For default anonymous images, no registry grant is required. Only when opting
   into private same-tenant ACR authentication, grant registry pull access as
   described in README before initialization can pull those images.

The administrator-only helper remains available, **outside azd hooks**:

```powershell
pwsh .\scripts\setup-entra.ps1 `
  -WebClientId <WEB_CLIENT_ID> `
  -AllowedObjectIds @("<operator-object-id>", "<demo1-object-id>", "<demo2-object-id>", `
    "<demo3-object-id>", "<demo4-object-id>", "<demo5-object-id>") `
  -GrantConsent
```

The runtime role helper `grant-graph-identity.ps1` is different: it runs inside
postprovision through `az rest`, without Microsoft Graph PowerShell modules or
an interactive `Connect-MgGraph`. It refuses a mismatched tenant/identity and
detects unsafe unscoped Entra Mail.Send. Permission/token-cache propagation may
delay app readiness after a new assignment; the hook does not bypass a 403.

It uses Microsoft.Graph.Applications and Microsoft.Graph.Identity.SignIns.
Its sign-in is intentionally interactive/administrator-controlled. The
registration hook does not invoke it.
After those prerequisites, run `azd deploy` or `azd up`. Initialization is not a
successful application deployment; before final deployment it only serves a
503 on port 80 and does not start the demo execution engine.

## Manual registration fallback and migration

If manually repairing an existing environment, obtain the saved PUBLIC_URL
(`azd env get-value PUBLIC_URL`) or Azure's actual `ipAddress.fqdn`. In Entra
admin center create a dedicated **single-tenant Web** registration,
disable implicit/public-client grants, configure the exact HTTPS URLs above,
request delegated `ChannelMessage.Send`, and emit SecurityGroup claims only if
needed. Under Certificates & secrets > Federated credentials, select **Managed
Identity** and trust the provisioned **user-assigned** identity using the issuer,
principal ID and audience above. No credential value needs copying or storage.

Set `azd env set WEB_CLIENT_ID <existing-client-id>` before provision to adopt an
existing dedicated registration. Unrelated API permissions or multitenant apps
are rejected for safety. Existing passwords/certificates are not automatically
deleted; revoke them after the secretless sign-in path has been verified. Existing
grants/assignments are not removed automatically; audit them separately.

The app and managed identity must be in the **same tenant**. This implementation
uses public Azure's exchange audience; sovereign-cloud federation is not
configured. A system-assigned identity is not a supported substitute here.

## Runtime token and session behavior

MSAL uses a lazy client-assertion callback. It obtains a managed-identity token
for `api://AzureADTokenExchange/.default` on demand; Azure Identity handles its
in-memory caching/refresh. That assertion authenticates the web app during
authorization-code redemption. Delegated Teams tokens belong to the signed-in
user, not the managed identity. Five authors still require five user sign-ins.

Direct mail/directory access instead requests
`https://graph.microsoft.com/.default` for the managed identity itself. Keep
those role grants scoped/reviewed independently from web-app delegated consent.

MSAL validates state/nonce/ID-token identity. The app additionally validates
tenant/object authorization. Opaque session cookies are Secure/HttpOnly/
SameSite=Lax; browser sessions expire within an hour. MSAL requests
`offline_access` and keeps access/refresh tokens in server memory only.
The administrator consent helper grants `ChannelMessage.Send offline_access`.
After updating an older deployment, rerun its reviewed consent setup and have
authors sign in again before starting background Teams workers.

Clicking **Start / resume my background Teams messages** authorizes that user's
pending activities for one started run, including cross-user dependencies.
The worker retains the session cache beyond browser cookie expiry until it
finishes, pauses for sign-in, is cancelled or the process stops. Silent renewal
runs before each send, not just before a potentially long delay. Closing a browser
does not stop the worker; token revocation or interaction requirements pause it
with pending steps intact. No tokens are persisted. Restart requires sign-in and
run resumption; interrupted Graph sends remain unknown and are not replayed.

Explicit CSRF-protected POST `/logout` clears the session and redirects to the
tenant logout endpoint. It also revokes future Teams sends authorized by that
session; in-flight Graph requests cannot be recalled. Front-channel
`/auth/signed-out` performs best-effort local invalidation and revocation;
third-party-cookie restrictions may prevent it from including the cookie.
Cancel a run as the operator to stop all not-yet-started work.

## Revocation and teardown

Disable enterprise sign-in, revoke consent/assignments, and remove the named
`aci-managed-identity` federated credential to revoke the web app trust. Remove
runtime Graph and Exchange grants independently. `azd down` deletes Azure
resources, **not the Entra app/enterprise principal**; delete those explicitly
after checking they are dedicated. Never delete unrelated app credentials/grants.

Key Vault is not provisioned or used by this authentication design. On an older
deployment, ARM incremental updates do not automatically remove a previously
deployed vault or role assignment: revoke any obsolete runtime Secrets User grant
explicitly, and delete the old web secret once migration is verified. Review
retention requirements before removing an unused legacy vault.

## Official reference

[Configure an application to trust a managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).
