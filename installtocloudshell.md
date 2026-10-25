# Install from Azure Cloud Shell

Deploy the already-published application image to Azure Container Instances
(ACI). Run the blocks **in order in the same Azure Cloud Shell PowerShell
session**, from the repository root after cloning. Do not select Bash.

This guide starts a **new deployment**. If you already have an azd environment,
use [Updating an existing deployment](#updating-an-existing-deployment) instead.
Cloud Shell does not need Docker or Python.

## 1. Before starting

- Use an **isolated Microsoft 365 CDX tenant**, never a production tenant.
- The Azure subscription must belong to that same tenant.
- Your deployment account needs Azure deployment rights plus Entra application
  management and Graph app-role assignment rights. Subscription Owner alone is
  not sufficient. Activate required administrator roles before provisioning.
  See [deployment identity prerequisites](docs/entra-setup.md#deployment-identity-prerequisites).
- Have a tenant administrator available for Teams consent and enterprise-app
  assignments, and an Exchange administrator for mailbox scope.
- Both published images must be anonymously pullable and reachable from ACI:
  - `acrdefcontainer.azurecr.io/azd-m365-demo-loader:latest`
  - `acrdefcontainer.azurecr.io/caddy:2.11.4-alpine`
- The app image must already contain the correct five users and Teams resource
  mappings. Changing JSON in Cloud Shell does **not** change a published image.
  The configuration used below must match the configuration packaged in it.

Keep delivery disabled until mailbox scope and the application dry run have
been verified. Do not use `azd up` for the first installation: administrator
setup belongs between provisioning and deployment.

## 2. Clone the repository and enter your settings

Open [Azure Cloud Shell](https://shell.azure.com/) and select **PowerShell**.

```powershell
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
if ($PSVersionTable.PSVersion -lt [version]"7.3") {
    throw "Use Cloud Shell PowerShell 7.3 or later."
}

git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata

az version
azd version
az account list --output table

$subscriptionId = Read-Host "Azure subscription ID"
$environmentName = Read-Host "New azd environment name (3-30 characters; use lowercase letters, numbers and hyphens)"
$location = "westeurope"
$acmeEmail = Read-Host "Administrator email address for HTTPS certificate notices"
$outOfScopeTestUpn = Read-Host "Existing SIXTH mailbox UPN for the forbidden-mailbox scope test (not one of the five demo users)"

az account set --subscription $subscriptionId
az account show --query "{subscription:name,subscriptionId:id,tenantId:tenantId}" --output table
$tenantId = az account show --query tenantId --output tsv

$confirmation = Read-Host "Verify the subscription and tenant above. Type CDX to confirm this is your isolated demo tenant"
if ($confirmation -cne "CDX") {
    throw "Stopped: isolated demo tenant not confirmed."
}

# azd and Azure CLI have separate authentication.
azd auth login --tenant-id $tenantId --use-device-code
```

If Azure CLI is not authenticated in the correct tenant, run the following,
then repeat the subscription selection and tenant confirmation above:

```powershell
az login --tenant $tenantId --use-device-code
az account set --subscription $subscriptionId
```

If the repository folder already exists, enter that checkout rather than
cloning over it. Run `git pull --ff-only` only after saving any local changes.
Unpushed local configuration will not appear in a new clone: securely upload
the matching configuration if necessary; do not commit tenant mappings publicly.

## 3. Check image references and read the five demo users

This selects the application image you just pushed and the configured Caddy
image. It changes only the Cloud Shell checkout.

```powershell
$imagesPath = Join-Path "config" "container-images.json"
$images = Get-Content -LiteralPath $imagesPath -Raw | ConvertFrom-Json
$images.services.app.image = "acrdefcontainer.azurecr.io/azd-m365-demo-loader:latest"
$images.services.caddy.image = "acrdefcontainer.azurecr.io/caddy:2.11.4-alpine"
$images | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $imagesPath -Encoding utf8
$images.services | Format-List

$demoConfig = Get-Content -LiteralPath (Join-Path "config" "demo-users.json") -Raw |
    ConvertFrom-Json
$demoUpns = @($demoConfig.users | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.userPrincipalName)) {
        throw "Each configured demo user must have a userPrincipalName."
    }
    $_.userPrincipalName
})
if ($demoUpns.Count -ne 5 -or @($demoUpns | Sort-Object -Unique).Count -ne 5) {
    throw "Expected exactly five distinct demo-user UPNs."
}
if ($outOfScopeTestUpn -in $demoUpns) {
    throw "The sixth test mailbox must not be one of the five demo users."
}
$demoUpns
Get-Content -LiteralPath (Join-Path "config" "resources.json")
```

**Stop if these are not the mappings packaged into your image.** The users must
already exist, have licenses/mailboxes, and belong to the mapped Teams channels.
An empty channel mapping permits startup but not Teams execution.

## 4. Create the azd environment

```powershell
azd env new $environmentName
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId
azd env set AZURE_LOCATION $location
azd env set DEMO_TENANT_CONFIRMED true
azd env set ACME_EMAIL $acmeEmail
azd env set DELIVERY_ENABLED false
azd env set MAILBOX_SCOPE_CONFIRMED false

$operatorId = az ad signed-in-user show --query id --output tsv
if ([string]::IsNullOrWhiteSpace($operatorId)) {
    throw "Could not retrieve the signed-in operator's Entra user object ID."
}
$operatorId = $operatorId.Trim()
azd env set OPERATOR_IDS $operatorId
```

This makes the signed-in Azure CLI user the application operator. Demo users
receive enterprise-app access later, not operator privileges.

## 5. Provision and register the application

```powershell
azd provision

$webClientId = azd env get-value WEB_CLIENT_ID
$identityClientId = azd env get-value AZURE_IDENTITY_CLIENT_ID
$identityPrincipalId = azd env get-value AZURE_IDENTITY_PRINCIPAL_ID
$publicUrl = azd env get-value PUBLIC_URL

Write-Host "Web application client ID: $webClientId"
Write-Host "Runtime identity client ID: $identityClientId"
Write-Host "Runtime identity principal ID: $identityPrincipalId"
Write-Host "Application URL: $publicUrl"
```

Provisioning installs Bicep if needed, creates Azure resources, assigns runtime
Graph `User.Read.All`, discovers the Azure hostname, and registers secretless
web authentication. It does not grant mail sending, delegated Teams consent, or
user access.

The app is deliberately dormant at this point: HTTP 503 is expected, and HTTPS
is not ready until final deployment. Do not manually invent a hostname or a web
client ID. If provisioning fails, fix the reported authorization/resource error
and rerun `azd provision`; do not proceed with incomplete outputs.

## 6. Assign users and grant Teams consent

Run as an authorized tenant administrator. These modules are needed only for
this administrator step, not for the deployment hooks.

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery -Force
Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Repository PSGallery -Force

# Include the operator and all five existing demo users.
$allowedIds = @($operatorId)
foreach ($upn in $demoUpns) {
    $id = az ad user show --id $upn --query id --output tsv
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "Could not resolve configured demo user: $upn"
    }
    $allowedIds += $id.Trim()
}
$allowedIds = @($allowedIds | Sort-Object -Unique)
foreach ($id in $allowedIds) { $null = [guid]::Parse($id) }

& (Join-Path "scripts" "setup-entra.ps1") `
    -WebClientId ([guid]$webClientId) `
    -AllowedObjectIds $allowedIds `
    -GrantConsent
```

Complete the Microsoft Graph sign-in in the **same CDX tenant**, using an
administrator permitted to assign users and grant delegated
`ChannelMessage.Send`. The helper leaves enterprise-app assignment required.
It is safe to rerun after partial completion.

If interactive module authentication cannot complete in Cloud Shell, use the
Entra portal: locate the app by `$webClientId`, grant admin consent under
**App registrations > API permissions**, then assign the operator and all five
users under **Enterprise applications > Users and groups**. Keep
**Assignment required = Yes**. Both consent and assignments are required.
See [Entra setup](docs/entra-setup.md) for details.

## 7. Configure and verify Exchange mailbox scope

Run as an Exchange administrator in the same CDX tenant. **Use the runtime
managed identity IDs here, not the web application ID.**

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Repository PSGallery -Force

& (Join-Path "scripts" "setup-exchange.ps1") `
    -ApplicationId ([guid]$identityClientId) `
    -PrincipalObjectId ([guid]$identityPrincipalId) `
    -DemoUpns $demoUpns `
    -OutOfScopeTestUpn $outOfScopeTestUpn `
    -ScopeName "$environmentName-FiveMailboxes"
```

Complete Exchange sign-in with your CDX Exchange administrator. Review the
authorization output: **all five demo mailboxes must be `InScope = True`; the
sixth mailbox must be `InScope = False`**. Permissions can take time to propagate;
rerun verification after propagation if necessary.

Do not grant an unscoped Graph application `Mail.Send` permission. Verify that
no other Exchange assignments or Entra grants broaden the runtime identity's
access. Do not enable delivery if scope verification fails.

If Cloud Shell cannot complete Exchange authentication, run this administrator
helper from a PowerShell 7 workstation with the same repository/configuration,
supplying the runtime identity IDs printed in step 5 and the same mailbox list.
Return to Cloud Shell after reviewing all scope results.

## 8. Deploy with delivery disabled and verify HTTPS

```powershell
azd deploy

$publicUrl = azd env get-value PUBLIC_URL
$health = Invoke-RestMethod -Uri "$publicUrl/healthz" -TimeoutSec 30
if ($health.status -ne "ready") {
    throw "Application is not ready."
}
$health
Write-Host "Open this URL in your browser: $publicUrl"
```

Deployment obtains the public HTTPS certificate and verifies readiness itself;
the additional request above confirms the published endpoint. Never disable TLS
certificate validation.

Open the URL, sign in as the operator, check the resolved users/resources,
upload a fictional scenario, and **run and inspect a dry run**. Teams authors
must each sign in separately to execute their own actions.

## 9. Optional: enable real delivery

**Do not paste this until the five allowed/one forbidden scope checks and the
application dry run have passed.** Real delivery sends mail and posts Teams
messages in your demo tenant.

```powershell
$confirmation = Read-Host "Type ENABLE after verifying mailbox scope and reviewing a successful dry run"
if ($confirmation -cne "ENABLE") {
    throw "Stopped: real delivery remains disabled."
}
azd env set MAILBOX_SCOPE_CONFIRMED true
azd env set DELIVERY_ENABLED true
azd deploy
```

## Diagnostics

Run from the same selected azd environment:

```powershell
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
$aciName = azd env get-value ACI_NAME

az container show --resource-group $resourceGroup --name $aciName `
    --query "{state:instanceView.state,fqdn:ipAddress.fqdn,containers:containers[].{name:name,image:image,state:instanceView.currentState.state,events:instanceView.events}}" `
    --output jsonc

az container logs --resource-group $resourceGroup --name $aciName --container-name app
az container logs --resource-group $resourceGroup --name $aciName --container-name https
```

For registration or runtime Graph authorization failures, check active Entra
roles and [Entra setup](docs/entra-setup.md). For readiness failures, check image
pulls, runtime `User.Read.All` propagation, federation, Caddy certificate logs,
public DNS, and ports 80/443. See [troubleshooting](docs/troubleshooting.md).

## Updating an existing deployment

Do not create a new environment for an existing installation. Select its saved
environment and use a **new immutable image tag or digest**. Reusing unchanged
`:latest` is not a reliable way to make ACI fetch a newly pushed image.

Export reports before updating. ACI updates/restarts can erase the temporary
journal and TLS state, including duplicate-send protection. Review prior sends
before running scenarios again after storage loss.

```powershell
azd env list
$existingEnvironment = Read-Host "Existing azd environment name"
azd env select $existingEnvironment

$newImage = Read-Host "Published app image with a NEW tag or sha256 digest (not unchanged :latest)"
$imagesPath = Join-Path "config" "container-images.json"
$images = Get-Content -LiteralPath $imagesPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($newImage) -or $newImage.EndsWith(":latest") -or
    $newImage -eq $images.services.app.image) {
    throw "Supply a new published tag or digest to reliably refresh the app image."
}
$images.services.app.image = $newImage
$images | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $imagesPath -Encoding utf8

azd deploy
azd env get-value PUBLIC_URL
```

If you pushed only `:latest`, obtain that image's manifest digest from your
registry and enter `acrdefcontainer.azurecr.io/azd-m365-demo-loader@sha256:...`,
or publish an additional unique tag before updating. With registry read rights,
this command prints the immutable reference to paste at the image prompt above:

```powershell
$digest = az acr repository show --name acrdefcontainer `
    --image "azd-m365-demo-loader:latest" --query digest --output tsv
if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "Could not read the published digest; obtain it from the registry publisher."
}
Write-Host "acrdefcontainer.azurecr.io/azd-m365-demo-loader@$digest"
```

Do not delete the running container group just to refresh an image. For
infrastructure or hostname changes, run `azd provision` before `azd deploy` to
reconcile resources and Entra URLs.
