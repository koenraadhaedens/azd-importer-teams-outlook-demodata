# Entra setup: secretless Azure ACI

The deployment target is Azure Container Instances. There is no local
client-secret authentication mode. Two identities still have different purposes:

- **Web app registration:** interactive OIDC sign-in and delegated
  `ChannelMessage.Send`, authenticated using the container's managed identity
  as a federated client assertion rather than a password/certificate.
- **ACI user-assigned managed identity:** direct runtime Graph/Exchange access,
  Blob storage, private registry pulls, and proof of identity to the web app.

The app registration is still required: a managed identity by itself does not
provide a web redirect URI or delegated user sign-in.

## Automatic registration during azd provisioning

[azure.yaml](../azure.yaml) invokes
[register-web-app.ps1](../scripts/register-web-app.ps1) as a **noninteractive
postprovision hook**, after the user-assigned identity exists and before ACI
deployment. Configure `PUBLIC_HOSTNAME` before provisioning. The hook:

1. Checks Azure CLI's tenant and the provisioned identity's tenant/principal.
2. Creates or updates a dedicated single-tenant application.
3. Derives URLs from `https://<PUBLIC_HOSTNAME>`:
   - redirect: `/auth/callback`
   - home/post-logout return: `/`
   - front-channel logout: `/auth/signed-out`
4. Requests delegated `ChannelMessage.Send` in the registration manifest.
   **Requesting a permission does not grant consent.**
5. Creates/updates a federated identity credential:
   - issuer: `https://login.microsoftonline.com/<tenant-id>/v2.0`
   - subject: managed identity **principal/object ID**, not client ID
   - audience: `api://AzureADTokenExchange`
6. Creates the enterprise service principal with assignment required.
7. Persists WEB_CLIENT_ID, WEB_APPLICATION_OBJECT_ID and
   WEB_SERVICE_PRINCIPAL_ID with `azd env set`. The deploy hook explicitly reads
   the saved client ID, including within the same `azd up`.

It creates **no client secret or certificate**, grants **no administrator
consent**, and makes **no user/group assignments**. Those boundaries are
intentional. Reruns reuse the saved client ID or uniquely named application and
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
with admin consent. This is powerful: restrict it to the protected deployment
environment and consider a tenant-admin-designed owned-app/custom-role setup if
you need tighter provisioning scope. That alternative must cover application
discovery, app/SP creation and updates, scope lookup and FIC management.

For a signed-in administrator's CLI, the authenticated account and CLI Graph
authorization must permit these operations under tenant policy. If permission
is missing the hook fails; it does not request interactive elevation.
**Never grant these setup privileges to the ACI runtime identity.**

## First-time sequence

```powershell
azd auth login
az login
azd env new my-demo-loader
azd env set PUBLIC_HOSTNAME loader.your-controlled-domain.example
# Configure other deployment settings from README; do not set a web secret.
azd provision
azd env get-value WEB_CLIENT_ID
```

Now an administrator must:

1. Grant tenant-admin-reviewed delegated `ChannelMessage.Send` consent.
2. Assign the operator(s) and five demo users, or explicit permitted security
   groups, to the enterprise app. Keep assignment required = Yes.
3. Configure OPERATOR_IDS or AUTHORIZED_GROUP_ID separately for application
   operator privileges; enterprise assignment is not an operator grant.
4. Grant the runtime identity direct application `User.Read.All` and configure
   the five-mailbox Exchange `Application Mail.Send` scope. Federation does not
   grant these permissions automatically.
5. Grant registry pull access and configure DNS as described in README.

The administrator-only helper remains available, **outside azd hooks**:

```powershell
pwsh .\scripts\setup-entra.ps1 `
  -WebClientId <WEB_CLIENT_ID> `
  -AllowedObjectIds @("<operator-object-id>", "<demo1-object-id>", "<demo2-object-id>", `
    "<demo3-object-id>", "<demo4-object-id>", "<demo5-object-id>") `
  -GrantConsent
```

It uses Microsoft.Graph.Applications and Microsoft.Graph.Identity.SignIns.
Its sign-in is intentionally interactive/administrator-controlled. The
registration hook does not invoke it.
After those prerequisites, run `azd deploy` or `azd up`.

## Manual registration fallback and migration

In Entra admin center create a dedicated **single-tenant Web** registration,
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
SameSite=Lax; tokens remain in server memory, with sessions expiring within an
hour. No offline refresh-token persistence is requested. Restart requires sign-in.

Explicit CSRF-protected POST `/logout` clears the session and redirects to the
tenant logout endpoint. Front-channel `/auth/signed-out` performs best-effort
local invalidation; third-party-cookie restrictions may prevent that callback
from including the cookie, so session expiry remains necessary.

## Revocation and teardown

Disable enterprise sign-in, revoke consent/assignments, and remove the named
`aci-managed-identity` federated credential to revoke the web app trust. Remove
runtime Graph and Exchange grants independently. `azd down` deletes Azure
resources, **not the Entra app/enterprise principal**; delete those explicitly
after checking they are dedicated. Never delete unrelated app credentials/grants.

Key Vault is retained as an infrastructure resource for optional future secrets,
but this authentication design does not read it or grant the runtime Secrets
User. On an existing deployment, ARM incremental updates do not automatically
remove a previously deployed vault role assignment: revoke the obsolete
runtime Secrets User grant explicitly, and delete the old web secret once
migration is verified.

## Official reference

[Configure an application to trust a managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).
