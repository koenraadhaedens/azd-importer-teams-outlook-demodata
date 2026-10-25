# Graph v1.0 permissions and scope

No beta endpoint is used. No migration permission or mailbox read permission is
requested. Azure RBAC/managed identity does **not** imply Graph permission.

| Runtime operation | Endpoint | Permission / identity |
|---|---|---|
| Resolve configured UPN | `GET /users?$filter=userPrincipalName eq '...'&$select=id,userPrincipalName&$top=2` | Application `User.Read.All`, runtime principal |
| Send demo email | `POST /users/{resolved-id}/sendMail` | Exchange `Application Mail.Send`, runtime principal, five-mailbox custom resource scope |
| Channel root message | `POST /teams/{team}/channels/{channel}/messages` | Delegated `ChannelMessage.Send`, interactive web app |
| Channel reply | `POST /teams/{team}/channels/{channel}/messages/{parent}/replies` | Delegated `ChannelMessage.Send`, interactive web app |
| Sign-in | tenant-specific authorize/token endpoints | OIDC `openid`, `profile`; no offline_access requested |

MSAL adds OIDC scopes; the client explicitly excludes `offline_access`.
It retains access tokens in per-session memory only. No delegated `Mail.Send`,
`User.Read`, `User.ReadBasic.All`, `ChatMessage.Send`, `Group.Read.All`,
`Directory.Read.All`, `Mail.Read`, `Mail.ReadWrite`, or `Teamwork.Migrate.All`
is needed. Team/channel IDs are configured, not broadly discovered.

`User.Read.All` requires administrator consent. The list-users **application**
permission table does not specify delegated `User.ReadBasic.All` as a supported
application alternative; do not confuse the two permission types.
Postprovision explicitly creates this app-role assignment for the verified ACI
identity using the already-authorized deployment identity. It does not prompt
for consent or elevate itself; missing setup privileges fail provisioning.

`ChannelMessage.Send` is not intrinsically admin-consent-only according to its
permission definition, but tenant consent policy can block user consent.
This repository requires administrator-reviewed tenant-wide delegated consent
and enterprise-app assignment, not arbitrary user self-consent.

## Preferred mail restriction: Application RBAC

Use [setup-exchange.ps1](../scripts/setup-exchange.ps1) for the runtime managed
identity's client ID and **enterprise service principal object ID**, not an app
registration object ID. It resolves the five UPNs to primary SMTP addresses,
defines an exact mailbox management scope, creates the Exchange pointer, assigns
`Application Mail.Send`, and displays authorization tests for five allowed
mailboxes plus one out-of-scope mailbox.

**Exchange RBAC and Entra grants are additive.** Do not grant that principal
tenant-wide Graph application Mail.Send as well. Remove broad existing grants
and inspect other Exchange role assignments. Confirm scope tests and propagation
before setting MAILBOX_SCOPE_CONFIRMED=true. The deployment/Graph script never
automatically grants tenant-wide Entra Mail.Send.

Runtime consent/authorization does not require broad mail reads. The app does
not create drafts or read Sent Items to infer successful delivery.

## Legacy alternative (not default automation)

Where an administrator deliberately chooses an existing Application Access Policy
setup: grant Graph application `Mail.Send` with admin consent; create a dedicated
mail-enabled security group containing only the five mailboxes; use Exchange
`New-ApplicationAccessPolicy -AppId <runtime-client-id> -PolicyScopeGroupId
<group-address> -AccessRight RestrictAccess` and verify allowed/denied mailboxes
with `Test-ApplicationAccessPolicy`. Policy propagation may be delayed.
Do not combine this with default RBAC and assume either restricts the other's
grants. Microsoft describes Application RBAC as the replacement.

## Setup permissions (not runtime)

- Noninteractive registration hook: pre-authorized deployment identity with
  Graph application `Application.ReadWrite.All` for dedicated app/SP/FIC
  creation and updates, plus `AppRoleAssignment.ReadWrite.All` for the automatic
  runtime `User.Read.All` grant. Application.ReadWrite.All covers the required
  application-read permission. Azure resource Owner alone does not authorize
  Graph. The hook grants no delegated Teams consent, mail permission or
  user/group assignment.
- Separate administrator helper: delegated `Application.Read.All` and
  `AppRoleAssignment.ReadWrite.All` for enterprise-app assignments.
- Administrator-only explicit delegated consent switch:
  `DelegatedPermissionGrant.ReadWrite.All`.
- Signed-in CLI administrator for runtime Graph-role assignment: effective
  `Application.Read.All` and `AppRoleAssignment.ReadWrite.All` (or supported
  higher privileges), with an appropriate Entra role for Microsoft Graph
  application-role grants, such as Privileged Role Administrator.
- Exchange setup: Exchange Administrator with appropriate Organization Management
  / Application RBAC delegating rights.

Disconnect administrator sessions after setup. None of these administrative
permissions belong on the runtime app.

The web app's federated credential trusts the ACI user-assigned managed identity
for audience `api://AzureADTokenExchange`. This is client authentication, not a
Graph permission or a replacement for user-interactive Teams consent. Direct
runtime Graph permissions remain on the managed identity itself.

## Official sources

- [List users](https://learn.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0)
- [Send mail](https://learn.microsoft.com/en-us/graph/api/user-sendmail?view=graph-rest-1.0)
- [Send channel message](https://learn.microsoft.com/en-us/graph/api/channel-post-messages?view=graph-rest-1.0)
- [Reply](https://learn.microsoft.com/en-us/graph/api/chatmessage-post-replies?view=graph-rest-1.0)
- [Permission reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Assign a service-principal app role](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0)
- [Exchange Application RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)
- [ACI temporary emptyDir volumes](https://learn.microsoft.com/en-us/azure/container-instances/container-instances-volume-emptydir)
