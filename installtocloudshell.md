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
- Use the new configuration-free application image. The same image works for
  every trainer; user/channel settings are supplied privately at deployment.
- Both image references in your private configuration must be published and
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

## 2. Upload or edit your local configuration

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Configure
```

The script displays the private configuration path and **pauses until you press
Enter**. It does not ask for names or email addresses individually. If the file
does not exist, it creates a demo-only copy at **ignored `config/config.local.json`**
with user-only permissions. Existing files are not overwritten.

While setup is paused, use Cloud Shell's **Upload/Download files > Upload** to
upload your own `config.json`, then move it to the displayed private path using
another terminal. Alternatively, open `config/config.local.json` in the Cloud
Shell editor and edit it. Set the certificate-notice email, excluded test mailbox,
five demo users' display names/UPNs, optional channel mappings, and published
`services` image references. Preserve the stable user keys for existing scenarios;
use `"channels": {}` for email-only scenarios.

Save or finish uploading **before pressing Enter**. Setup then reads and validates
that file. Rerunning Configure pauses again so you can replace or edit it; later
stages reuse the saved file without individual questions. The tracked
[config.json](config/config.json) remains fictional; do not put trainer details there.
If you replace the private file by uploading, ensure its permissions remain private.

- `acmeEmail`: administrative email for HTTPS certificate notices.
- `outOfScopeTestUpn`: an **existing sixth mailbox**, not one of `x-demo.users`.
  It is only used to test that the runtime identity cannot access it. Setup does
  not assign this user to the app or send mail to it.

Configuration is validated before deployment. The Exchange helper additionally
rejects aliases that resolve to one of the five allowed mailboxes.
Treat this file and Cloud Shell storage as private administrator data; it is not
encrypted at rest by the script. Do not share it or include it in support logs.
Custom files can be supplied with `-Config <path>` on every stage; keep them
outside version control. The selected file path, not its contents, is saved to azd.

User/channel mappings are passed through ACI **secure environment values**;
certificate email uses a separate secure value. The excluded mailbox is not sent
to the runtime. Neither Git nor the image contains your answers. Changing these
settings requires redeployment and permission review, **not an image rebuild**.
Azure administrators and processes inside the relevant containers can still
access runtime values. Avoid debug/verbose deployment output or shell transcripts
when handling private configuration.

### Migrating an older installation

Publish a new application image once to adopt this configuration-free runtime.
Existing local configuration can be reused by placing it in
`config/config.local.json`. Preserve its logical user keys for existing scenarios.
Update its image reference to the newly published unique tag/digest.

Removing data from the current checkout does not erase Git history, previously
published images, deployment records, or old azd values. Review and retire old
images/tags and remove previously saved ACME_EMAIL values as appropriate.
Coordinate any Git-history cleanup separately; do not rewrite shared history
automatically. Rebuilds are unnecessary for subsequent trainer-setting changes.

## 3. Provision with delivery disabled

After verifying the isolated CDX tenant/subscription:

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1 -Stage Provision -ConfirmDemoTenant
```

On a fresh checkout, `azd provision` asks for the new **environment name**,
**subscription**, and **location**. Select the same tenant/subscription as Azure
CLI. These choices and authentication remain interactive. If the private file
does not exist, setup first pauses for you to upload or edit it and confirm.
No copying of IDs/settings is needed.

[setup.ps1](scripts/setup.ps1) reads the certificate email, resolves your
signed-in operator object ID, provisions, and saves operational flags and the
private configuration path into the selected environment. Emails and mappings
are not passed as `azd env set` arguments. Delivery and mailbox-scope confirmation
remain **false**.
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
PowerShell 7 administrator workstation with a private copy of the configuration,
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

Before upgrading application code, change the app image in the private configuration
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
Shell and ensure its private configuration contains the same pushed reference.
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

If using a custom private file path, supply `-Config <path>` to the Deploy stage
with explicit scope confirmation to save that path for future hooks.
