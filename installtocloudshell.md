# Install from Azure Cloud Shell

Open **PowerShell** in [Azure Cloud Shell](https://shell.azure.com/).
Tools and Azure CLI sign-in are assumed to be available.

This is a **fresh installation** using your already-published app image.
Copy **one snippet at a time**, wait for completion, and stop on errors.
Keep the same shell open throughout.

Before starting:

- Use an isolated CDX tenant and a subscription in that tenant.
- Your account needs Azure deployment rights and the Entra administrator rights
  described in [Entra setup](docs/entra-setup.md#deployment-identity-prerequisites).
- The published app must contain your correct five users and Teams mappings.
  The checkout used below must contain the same configuration.
- Both images in [container-images.json](config/container-images.json) must be
  published and anonymously pullable.

## 1. Clone and open the project

```powershell
git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata
```

If you already have the checkout, enter that folder instead of cloning again.

## 2. Stop on command errors

```powershell
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
```

## 3. Sign in to azd

Complete the sign-in with your CDX deployment account. Azure CLI and azd have
separate authentication.

```powershell
azd auth login --use-device-code
```

## 4. Create an environment

Choose a new environment name when prompted.

```powershell
azd env new
```

## 5. Save the demo settings

Only confirm this after verifying you are using the isolated CDX tenant.
Enter an email address for HTTPS certificate notices.

```powershell
azd env set DEMO_TENANT_CONFIRMED true
azd env set ACME_EMAIL (Read-Host "Email for certificate notices")
azd env set DELIVERY_ENABLED false
azd env set MAILBOX_SCOPE_CONFIRMED false
```

## 6. Set yourself as the operator

```powershell
$operatorId = az ad signed-in-user show --query id --output tsv
if ([string]::IsNullOrWhiteSpace($operatorId)) {
    throw "Could not resolve the signed-in operator."
}
$operatorId = $operatorId.Trim()
azd env set OPERATOR_IDS $operatorId
```

## 7. Check the published images

```powershell
Get-Content -LiteralPath (Join-Path "config" "container-images.json")
```

The app should be `acrdefcontainer.azurecr.io/azd-m365-demo-loader:latest`,
and Caddy should be `acrdefcontainer.azurecr.io/caddy:2.11.4-alpine`.
No build or push is performed in Cloud Shell.

## 8. Provision

Select your **subscription and location when azd prompts**; there is no need to
set them manually beforehand. Azure CLI must also be authenticated in the same
target tenant/subscription because the hooks use it.

```powershell
azd provision
```

Wait until provisioning succeeds. It creates the Azure resources, runtime Graph
grant, public hostname, and secretless web registration.
The app is intentionally dormant until the administrator steps below are done.
Do not use `azd up` to skip those steps.

## 9. Read the generated IDs

```powershell
$webClientId = azd env get-value WEB_CLIENT_ID
$identityClientId = azd env get-value AZURE_IDENTITY_CLIENT_ID
$identityPrincipalId = azd env get-value AZURE_IDENTITY_PRINCIPAL_ID
$environmentName = azd env get-value AZURE_ENV_NAME
```

## 10. Read the five configured demo users

These must match the users packaged in the published image. Editing the
checkout does not update that image.

```powershell
$demoConfig = Get-Content -LiteralPath (Join-Path "config" "demo-users.json") -Raw |
    ConvertFrom-Json
$demoUpns = @($demoConfig.users | ForEach-Object { $_.userPrincipalName })
if ($demoUpns.Count -ne 5 -or
    @($demoUpns | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
    @($demoUpns | Sort-Object -Unique).Count -ne 5) {
    throw "Expected exactly five distinct, nonempty demo-user UPNs."
}
$demoUpns
```

## 11. Install the administrator modules

These are additional modules used by the permission helpers, not Cloud Shell
deployment prerequisites.

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
```

## 12. Resolve the users for application access

```powershell
$allowedIds = @($operatorId)
foreach ($upn in $demoUpns) {
    $id = az ad user show --id $upn --query id --output tsv
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "Could not resolve demo user: $upn"
    }
    $allowedIds += $id.Trim()
}
$allowedIds = @($allowedIds | Sort-Object -Unique)
```

## 13. Assign users and grant Teams consent

Complete the helper's sign-in as an authorized administrator **in the CDX tenant**.
This assigns the operator and five demo users and grants delegated
`ChannelMessage.Send` consent.

```powershell
& (Join-Path "scripts" "setup-entra.ps1") `
    -WebClientId ([guid]$webClientId) `
    -AllowedObjectIds $allowedIds `
    -GrantConsent
```

If module sign-in cannot complete in Cloud Shell, use the Entra portal:
find the application by `$webClientId`, grant admin consent under
**App registrations > API permissions**, then assign the operator and five
users under **Enterprise applications > Users and groups**.
Keep **Assignment required = Yes**.

## 14. Choose the forbidden-mailbox test account

Enter an existing sixth mailbox that is **not** one of the five demo users.

```powershell
$outOfScopeTestUpn = Read-Host "Sixth mailbox UPN for the out-of-scope test"
```

## 15. Configure Exchange mailbox scope

Complete sign-in as your CDX Exchange administrator. These parameters use the
**runtime managed identity**, not the web application.

```powershell
& (Join-Path "scripts" "setup-exchange.ps1") `
    -ApplicationId ([guid]$identityClientId) `
    -PrincipalObjectId ([guid]$identityPrincipalId) `
    -DemoUpns $demoUpns `
    -OutOfScopeTestUpn $outOfScopeTestUpn `
    -ScopeName "$environmentName-FiveMailboxes"
```

**Check the results before continuing:** five mailboxes must have
`InScope = True`; the sixth must have `InScope = False`.
Allow time for permission propagation if needed.
Do not grant unscoped Graph application `Mail.Send`, or leave other grants that
broaden mailbox access.

If Exchange sign-in is unavailable in Cloud Shell, run this helper from a
PowerShell 7 administrator workstation with the same configuration and identity
IDs, then return here after verifying scope.

## 16. Deploy with real delivery disabled

```powershell
azd deploy
```

Wait for deployment, certificate issuance, and HTTPS readiness to succeed.

## 17. Open the application

```powershell
azd env get-value PUBLIC_URL
```

Open the displayed URL, sign in as the operator, verify the resolved
users/resources, and inspect a **successful dry run**.
Each Teams author signs in separately to execute their own actions.

## 18. Optional: enable real delivery

Only do this after verifying mailbox scope and the dry run. This permits real
mail and Teams posts in the demo tenant.

```powershell
azd env set MAILBOX_SCOPE_CONFIRMED true
azd env set DELIVERY_ENABLED true
```

Apply the settings:

```powershell
azd deploy
```

## If deployment fails

Get the resource names:

```powershell
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
$aciName = azd env get-value ACI_NAME
```

Read the application logs:

```powershell
az container logs --resource-group $resourceGroup --name $aciName --container-name app
```

Read the HTTPS proxy logs:

```powershell
az container logs --resource-group $resourceGroup --name $aciName --container-name https
```

See [troubleshooting](docs/troubleshooting.md) for permission, image-pull,
federation, and certificate problems.

## Updating an existing deployment

Use your existing checkout and select its saved environment:

```powershell
azd env list
azd env select (Read-Host "Existing environment name")
```

Before redeploying, change the app image in
[container-images.json](config/container-images.json) to a newly published
unique tag or digest. Reusing unchanged `:latest` does not reliably refresh ACI.
See [update instructions](README.md#updating-an-installed-environment).

Export reports first: ACI updates can erase the temporary journal and
duplicate-send protection. Review prior sends before running scenarios again.

```powershell
azd deploy
```
