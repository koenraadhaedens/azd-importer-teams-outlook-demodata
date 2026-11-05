# Install from Azure Cloud Shell

Open **PowerShell** in [Azure Cloud Shell](https://shell.azure.com/).
Tools and Azure CLI sign-in are assumed to be available.

This is a **fresh installation** using already-published images. It enables
**real delivery** only after administrator-reviewed mailbox-scope verification.
No scenario is executed by setup; inspect a successful dry run before explicitly
starting a reviewed executable scenario.

Before starting:

- Use an isolated CDX tenant and a subscription in that tenant.
- Your account needs Azure deployment rights and the Entra administrator rights
  described in [Entra setup](docs/entra-setup.md#deployment-identity-prerequisites).
- The published app must contain your correct five users and Teams mappings.
  The checkout must contain the same configuration.
- Both images in [config.json](config/config.json) must be published and
  anonymously pullable, including their exact tags. Building locally or pushing
  only `:latest` does not publish another tag.

Public ACR images require no registry credentials, `az acr login`, or `AcrPull`
grant for the runtime identity. Leave `USE_MANAGED_IDENTITY_FOR_IMAGE_PULL` unset
or false. An azd "key not found" message for this optional value is expected.

Provisioning creates the resource group and runtime managed identity; its hook
adds dormant ACI and the secretless web registration. No Key Vault, Log Analytics
workspace or storage account is provisioned. Do not use `azd up` to skip the
administrator steps.

## 1. Clone and sign in

```powershell
git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata
azd auth login --use-device-code
```

If you already have the checkout, enter that folder instead of cloning again.
Azure CLI and azd authenticate separately. Confirm Azure CLI's selected
subscription and tenant before proceeding:

```powershell
az account show --query "{subscription:name,tenantId:tenantId}" --output table
```

Use `az account set --subscription "<subscription-id>"` if needed. Complete azd
sign-in with your CDX deployment account.

## 2. Edit the configuration once

Set these two fields in [config.json](config/config.json):

```json
"x-setup": {
  "acmeEmail": "certificate-notices@example.org",
  "outOfScopeTestUpn": "existing-sixth-mailbox@your-demo-tenant.example"
}
```

Replace both examples with real addresses:

- `acmeEmail`: administrative email for HTTPS certificate notices.
- `outOfScopeTestUpn`: an **existing sixth mailbox**, not one of `x-demo.users`.
  It is only used to test that the runtime identity cannot access it. Setup does
  not assign this user to the app or send mail to it.

Retain `services`, the five `x-demo.users`, and `x-demo.channels`.
Blank or invalid emails and a sixth UPN matching a demo user are rejected before
setup contacts Azure. The Exchange helper additionally resolves primary SMTP
addresses and rejects aliases that resolve to one of the five demo mailboxes.
Never put credentials in this file or publish tenant configuration accidentally.

Changing only `x-setup` requires no image rebuild; these are setup-tool settings,
not runtime user/channel mappings. Changing packaged mappings still requires a
newly built and published app image. The certificate email is saved into the azd
environment by setup. A custom file can be supplied with `-Config <path>` on
each stage; its mappings must match the published image.

## 3. Provision with delivery disabled

After verifying the isolated CDX tenant/subscription:

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Provision -ConfirmDemoTenant
```

On a fresh checkout, `azd provision` asks for the new **environment name**,
**subscription**, and **location**. Select the same tenant/subscription as Azure
CLI. These choices and authentication remain interactive; the email questions
and copying of IDs/settings are removed.

[setup.ps1](scripts/setup.ps1) reads the certificate email, resolves your
signed-in operator object ID, provisions, and saves all prepared values into the
selected environment. Delivery and mailbox-scope confirmation remain **false**.
Wait for success and resolve errors before proceeding.

## 4. Assign users and grant Teams consent

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Entra -InstallModules
```

The script reads the selected environment's web client ID and configured operator
IDs, resolves the five demo users, and calls [setup-entra.ps1](scripts/setup-entra.ps1)
to assign them and grant delegated `ChannelMessage.Send` / `offline_access`
consent. `-InstallModules` installs only missing administrator modules for the
current user; omit it if they are already installed.

Complete module sign-in as an authorized administrator **in the CDX tenant**.
If module sign-in is unavailable in Cloud Shell, use the Entra portal or an
administrator workstation: find the app by `azd env get-value WEB_CLIENT_ID`,
grant admin consent under **App registrations > API permissions**, then assign
the operator and five users under **Enterprise applications > Users and groups**.
Keep **Assignment required = Yes**.

## 5. Configure and review Exchange mailbox scope

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Exchange -InstallModules
```

Each stage command starts and exits a separate clean PowerShell process. This
keeps Microsoft Graph and Exchange assemblies isolated; no nested interactive
shell or manual variable reload is needed. Do not dot-source these stage commands
into a process that already loaded Graph modules.

The script reads the runtime identity IDs, environment name, five demo users,
and excluded test mailbox, then calls [setup-exchange.ps1](scripts/setup-exchange.ps1).
Complete sign-in as your CDX Exchange administrator.

**Review before continuing:** `Application Mail.Send` must show five demo
mailboxes with `InScope = True` and the sixth with `InScope = False`. Allow time
for propagation and rerun this stage if necessary. Also review additive grants:
do not grant unscoped Graph application `Mail.Send` or leave other Exchange
assignments that broaden access. This review is not automatically confirmed.

If Exchange sign-in is unavailable in Cloud Shell, run this stage from a
PowerShell 7 administrator workstation with the same checkout/configuration,
selected azd environment, and Azure CLI authentication. Return here only after
verification succeeds.

### Recovering from an existing Exchange scope after a fresh deployment

Deleting an Azure resource group or running `azd down` does **not** delete
tenant-level Entra apps, Exchange service-principal registrations, scopes, or
role assignments. A fresh environment is not a completely clean Microsoft 365
tenant.

The current helper reuses a scope with exactly the same five primary SMTP
predicates, regardless of their order, case or parentheses. Each runtime identity
gets its own `DemoMailSend-<principal-object-id>` assignment. It never changes
another identity's scope or assignment.

For older-helper errors such as **"Use the existing management scope instead of
creating a new one"** or **"management scope wasn't found"**, update the checkout,
select the intended environment with `azd env list` /
`azd env select <name>`, and rerun the Exchange stage above. Do not retry a failing
assignment with a guessed scope name.

The helper prints the resolved scope name and tests all six mailboxes.
Multiple equivalent scopes or conflicting scopes/principals/assignments require
manual review. For an explicitly reviewed scope name, use
[setup-exchange.ps1](scripts/setup-exchange.ps1) directly with `-ScopeName` and
the selected environment's runtime identity IDs.
Do not remove old registrations or assignments until confirmed retired.
`WEB_CLIENT_ID` identifies the web app, not the runtime identity used for Exchange.

## 6. Confirm scope and deploy

Only after the five allowed / one excluded results and additive grants have
been reviewed:

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Deploy -ConfirmMailboxScope
```

This explicitly saves mailbox-scope confirmation, enables real delivery, and
runs `azd deploy`. Wait for deployment, certificate issuance, and TLS-verified
HTTPS readiness. The script prints the application URL. It does not execute
scenarios.

Open the URL, sign in as the operator, verify users/resources, and inspect a
**successful dry run**. Scenarios marked `dryRun: true` remain non-executable.
For real demo delivery, preview a reviewed `dryRun: false` scenario and explicitly
confirm execution as the operator.

Each Teams author signs in separately in an isolated browser session and clicks
**Start / resume my background Teams messages** once for the run. Workers then
wait for dependencies and renew tokens in server memory; the browser may close.
Do not sign out while expecting future sends. If sign-in is required again,
resume the same run. After a container restart, the operator and unfinished
authors must resume. No access or refresh tokens are stored on disk.

When upgrading an older image, repeat the Entra stage to include `offline_access`
and have authors sign in again.

## If deployment fails

If the hook shows only `Azure CLI operation failed: deployment`, retrieve the
recorded error before retrying; that summary is not evidence that registry
authentication is required:

```powershell
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
$aciName = azd env get-value ACI_NAME
az deployment group show --resource-group $resourceGroup --name aci-app `
    --query properties.error --output json
az deployment operation group list --resource-group $resourceGroup --name aci-app `
    --query "[?properties.provisioningState=='Failed'].properties.statusMessage" --output json
```

For `InaccessibleImage`, compare the exact reference with
[config.json](config/config.json). Public access does not make a missing tag
available. Publish the requested tag on the build workstation, then retry
`azd deploy`. Do not add credentials to fix a missing public tag.

Read logs without redeploying:

```powershell
az container logs --resource-group $resourceGroup --name $aciName --container-name app
az container logs --resource-group $resourceGroup --name $aciName --container-name https
```

See [troubleshooting](docs/troubleshooting.md) for permission, image-pull,
federation, and certificate problems.

## Updating an existing deployment

Select its saved environment:

```powershell
azd env list
azd env select (Read-Host "Existing environment name")
```

Before redeploying, change the app image in [config.json](config/config.json)
to a newly published unique tag or digest. Reusing unchanged `:latest` does not
reliably refresh ACI. See [update instructions](README.md#updating-an-installed-environment).

On the **Docker build workstation**, publish the exact configured reference:

```powershell
$images = Get-Content -LiteralPath (Join-Path "config" "config.json") -Raw |
    ConvertFrom-Json
docker build --platform linux/amd64 -t $images.services.app.image .
if ($LASTEXITCODE -ne 0) { throw "App image build failed; do not deploy." }
docker push $images.services.app.image
if ($LASTEXITCODE -ne 0) { throw "App image push failed; do not deploy." }
```

Publisher authentication is separate from ACI's anonymous pull. Return to Cloud
Shell and ensure its configuration contains the same pushed reference.
Deployment does not build, push, or create missing tags.

Export reports first: ACI updates can erase the temporary journal and
duplicate-send protection. Review prior sends before running scenarios again.
Incremental provisioning does not remove legacy Key Vault / Log Analytics
resources. Review unused resources separately, preserving required logs/secrets
and respecting retention/purge protection.

For an existing installation with already-reviewed permissions:

```powershell
azd deploy
```

If changing the certificate-notice email, rerun the Deploy stage with explicit
scope confirmation to save the updated email before deploying.
