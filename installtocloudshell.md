# Install from Azure Cloud Shell

Open **PowerShell** in [Azure Cloud Shell](https://shell.azure.com/).
Use an isolated CDX demo tenant. You need Azure deployment rights and
[Entra/Exchange administrator permissions](docs/entra-setup.md#deployment-identity-prerequisites).
Setup uses already-published container images; no image build is needed.

Clone the repository and sign in:

```powershell
git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata
azd auth login --use-device-code
```

If already cloned, enter the existing folder. Cloud Shell normally signs in
Azure CLI automatically; if needed, run `az login --use-device-code` too.

## 1. Update your local configuration first

In the Cloud Shell editor, open [config/config.json](config/config.json) and
**save a copy as `config/config.local.json`**. Or upload your own configuration
using **Upload/Download files > Upload** and place it at that local path.
Do not overwrite the published template.

In your local file, update:

- `x-demo.users`: the five users' names and UPNs; keep their existing `key` values.
- `x-setup.acmeEmail`: your certificate-notice email.
- `x-setup.outOfScopeTestUpn`: an existing sixth mailbox, outside the five demo users.
- `x-demo.channels`: your Teams mappings, or `{}` for email-only demos.

Keep the published `services` images unless using your own published images.
Keep this local file private; it is ignored by Git.

## 2. Run setup

```powershell
pwsh -NoProfile -File ./scripts/setup.ps1
```

Setup first pauses so you can finish uploading or editing the local file.
**Press Enter when it is ready.** No individual names or email addresses are asked.

Then follow the prompts:

1. Confirm the displayed demo tenant/subscription.
2. Choose an environment name, subscription, and location when asked.
3. Sign in for Entra and Exchange administration. Required modules install automatically.
4. Review the mailbox results: **five `InScope=True`, sixth `InScope=False`**,
   with no other grants broadening access. Type **YES** only when correct.

Setup provisions Azure resources, assigns users, configures permissions, and
deploys the app automatically. Real delivery stays disabled until your final
confirmation. No scenarios run during setup.

## 3. Open the app

Open the URL printed by setup and sign in. Upload a scenario and check a
**successful dry run** before starting real delivery.
For Teams scenarios, each author signs in separately and starts their background
messages for the run.

If setup stops, fix the reported error and use its `-Stage` command to retry
that stage. Individual stages remain available for administrators; after a
successful retry, run the remaining stages in order: Provision, Entra, Exchange,
Deploy. See the [manual setup](README.md#azure-portal-cloud-shell-powershell) and
[troubleshooting](docs/troubleshooting.md).

<details>
<summary>Advanced: deployment errors and updates</summary>

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

</details>
