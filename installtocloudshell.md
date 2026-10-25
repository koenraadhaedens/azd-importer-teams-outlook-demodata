# Install from Azure Cloud Shell

Deploy the already-published application image to Azure Container Instances
(ACI). Run the blocks **in order in the same Azure Cloud Shell PowerShell
session**, from the repository root after cloning. Do not select Bash.

**Copy only one code block at a time.** Wait for it to finish, complete any
sign-in prompt, and check the result before moving to the next numbered step.
If a command fails, stop and fix it before continuing. Keep the same shell open:
later snippets reuse variables from earlier steps.

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

### 2.1. Set error handling and check PowerShell

```powershell
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
if ($PSVersionTable.PSVersion -lt [version]"7.3") {
    throw "Use Cloud Shell PowerShell 7.3 or later."
}
```

### 2.2. Clone the repository

For a new checkout, paste:

```powershell
git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata
```

If the folder already exists, enter that checkout instead. Do not clone over it.
Run `git pull --ff-only` only after saving local changes.

### 2.3. Check tools and list subscriptions

```powershell
az version
azd version
az account list --output table
```

**Check:** both tools work and your target subscription appears.

### 2.4. Enter your subscription

Copy the block, then answer the prompt:

```powershell
$subscriptionId = Read-Host "Azure subscription ID"
```

### 2.5. Select the subscription and display the tenant

```powershell
az account set --subscription $subscriptionId
az account show --query "{subscription:name,subscriptionId:id,tenantId:tenantId}" --output table
$tenantId = az account show --query tenantId --output tsv
```

**Check:** the displayed subscription belongs to your isolated CDX tenant.

### 2.6. Confirm the demo tenant

```powershell
$confirmation = Read-Host "Verify the subscription and tenant above. Type CDX to confirm this is your isolated demo tenant"
if ($confirmation -cne "CDX") {
    throw "Stopped: isolated demo tenant not confirmed."
}
```

### 2.7. Enter your deployment settings

Answer each prompt. The sixth mailbox is an existing mailbox **outside** your
five demo users.

```powershell
$environmentName = Read-Host "New azd environment name (3-30 characters; use lowercase letters, numbers and hyphens)"
$location = "westeurope"
$acmeEmail = Read-Host "Administrator email address for HTTPS certificate notices"
$outOfScopeTestUpn = Read-Host "Existing SIXTH mailbox UPN for the forbidden-mailbox scope test (not one of the five demo users)"
```

### 2.8. Sign in to Azure Developer CLI

Azure CLI and azd have separate authentication. Finish the device-code sign-in
before continuing.

```powershell
azd auth login --tenant-id $tenantId --use-device-code
```

**Only if Azure CLI authentication failed earlier:** enter your CDX tenant ID
below, sign in, then repeat steps 2.5 and 2.6:

```powershell
$tenantId = Read-Host "CDX tenant ID"
az login --tenant $tenantId --use-device-code
az account set --subscription $subscriptionId
```

Unpushed local configuration will not appear in a new clone: securely upload
the matching configuration if necessary; do not commit tenant mappings publicly.

## 3. Check image references and read the five demo users

This selects the application image you just pushed and the configured Caddy
image. It changes only the Cloud Shell checkout.

### 3.1. Select the published images

```powershell
$imagesPath = Join-Path "config" "container-images.json"
$images = Get-Content -LiteralPath $imagesPath -Raw | ConvertFrom-Json
$images.services.app.image = "acrdefcontainer.azurecr.io/azd-m365-demo-loader:latest"
$images.services.caddy.image = "acrdefcontainer.azurecr.io/caddy:2.11.4-alpine"
$images | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $imagesPath -Encoding utf8
$images.services | Format-List
```

**Check:** the output shows the app `:latest` and Caddy `:2.11.4-alpine`.

### 3.2. Read the five demo users

```powershell
$demoConfig = Get-Content -LiteralPath (Join-Path "config" "demo-users.json") -Raw |
    ConvertFrom-Json
$demoUpns = @($demoConfig.users | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.userPrincipalName)) {
        throw "Each configured demo user must have a userPrincipalName."
    }
    $_.userPrincipalName
})
```

### 3.3. Validate and display the user list

```powershell
if ($demoUpns.Count -ne 5 -or @($demoUpns | Sort-Object -Unique).Count -ne 5) {
    throw "Expected exactly five distinct demo-user UPNs."
}
if ($outOfScopeTestUpn -in $demoUpns) {
    throw "The sixth test mailbox must not be one of the five demo users."
}
$demoUpns
```

### 3.4. Display the Teams mappings

```powershell
Get-Content -LiteralPath (Join-Path "config" "resources.json")
```

**Stop if these are not the mappings packaged into your image.** The users must
already exist, have licenses/mailboxes, and belong to the mapped Teams channels.
An empty channel mapping permits startup but not Teams execution.

## 4. Create the azd environment

### 4.1. Create the environment

```powershell
azd env new $environmentName
```

Wait for environment creation to finish.

### 4.2. Save subscription and location

```powershell
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId
azd env set AZURE_LOCATION $location
```

### 4.3. Save demo settings with delivery disabled

```powershell
azd env set DEMO_TENANT_CONFIRMED true
azd env set ACME_EMAIL $acmeEmail
azd env set DELIVERY_ENABLED false
azd env set MAILBOX_SCOPE_CONFIRMED false
```

### 4.4. Set yourself as the operator

```powershell
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

### 5.1. Provision Azure resources

This can take several minutes. **Wait for successful completion** before
copying the next snippet.

```powershell
azd provision
```

### 5.2. Read the generated IDs

```powershell
$webClientId = azd env get-value WEB_CLIENT_ID
$identityClientId = azd env get-value AZURE_IDENTITY_CLIENT_ID
$identityPrincipalId = azd env get-value AZURE_IDENTITY_PRINCIPAL_ID
$publicUrl = azd env get-value PUBLIC_URL
```

### 5.3. Display the generated settings

```powershell
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

### 6.1. Install the Graph administrator modules

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery -Force
Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Repository PSGallery -Force
```

### 6.2. Resolve the operator and demo users

```powershell
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
```

### 6.3. Apply assignments and grant consent

```powershell
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

### 7.1. Install the Exchange administrator module

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Repository PSGallery -Force
```

### 7.2. Configure mailbox scope

```powershell
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

**Checkpoint:** do not continue unless all five allowed mailboxes and the sixth
forbidden mailbox have the expected scope results.

Do not grant an unscoped Graph application `Mail.Send` permission. Verify that
no other Exchange assignments or Entra grants broaden the runtime identity's
access. Do not enable delivery if scope verification fails.

If Cloud Shell cannot complete Exchange authentication, run this administrator
helper from a PowerShell 7 workstation with the same repository/configuration,
supplying the runtime identity IDs printed in step 5.3 and the same mailbox list.
Return to Cloud Shell after reviewing all scope results.

## 8. Deploy with delivery disabled and verify HTTPS

### 8.1. Deploy the application

Wait for successful deployment and certificate/readiness checks.

```powershell
azd deploy
```

### 8.2. Verify the public health endpoint

```powershell
$publicUrl = azd env get-value PUBLIC_URL
$health = Invoke-RestMethod -Uri "$publicUrl/healthz" -TimeoutSec 30
if ($health.status -ne "ready") {
    throw "Application is not ready."
}
$health
```

**Check:** the response reports `status: ready`.

### 8.3. Get the browser URL

```powershell
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

### 9.1. Confirm your checks and enable delivery

```powershell
$confirmation = Read-Host "Type ENABLE after verifying mailbox scope and reviewing a successful dry run"
if ($confirmation -cne "ENABLE") {
    throw "Stopped: real delivery remains disabled."
}
azd env set MAILBOX_SCOPE_CONFIRMED true
azd env set DELIVERY_ENABLED true
```

### 9.2. Apply the delivery settings

```powershell
azd deploy
```

## Diagnostics

Run from the same selected azd environment:

### D1. Read the resource names

```powershell
$resourceGroup = azd env get-value AZURE_RESOURCE_GROUP
$aciName = azd env get-value ACI_NAME
```

### D2. Check container state and events

```powershell
az container show --resource-group $resourceGroup --name $aciName `
    --query "{state:instanceView.state,fqdn:ipAddress.fqdn,containers:containers[].{name:name,image:image,state:instanceView.currentState.state,events:instanceView.events}}" `
    --output jsonc
```

### D3. Read application logs

```powershell
az container logs --resource-group $resourceGroup --name $aciName --container-name app
```

### D4. Read HTTPS proxy logs

```powershell
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

Use the same PowerShell error handling from step 2.1 and enter your repository
checkout first.

### U1. Select your existing environment

```powershell
azd env list
$existingEnvironment = Read-Host "Existing azd environment name"
azd env select $existingEnvironment
```

### U2. Obtain the digest of your newly pushed latest image

With registry read rights, this prints an immutable reference. Copy the printed
reference for step U3. Without registry read rights, ask the registry publisher
for the digest or a new unique published tag.

```powershell
$digest = az acr repository show --name acrdefcontainer `
    --image "azd-m365-demo-loader:latest" --query digest --output tsv
if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "Could not read the published digest; obtain it from the registry publisher."
}
Write-Host "acrdefcontainer.azurecr.io/azd-m365-demo-loader@$digest"
```

### U3. Enter the immutable image reference

```powershell
$newImage = Read-Host "Published app image with a NEW tag or sha256 digest (not unchanged :latest)"
```

### U4. Save the new image reference

```powershell
$imagesPath = Join-Path "config" "container-images.json"
$images = Get-Content -LiteralPath $imagesPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($newImage) -or $newImage.EndsWith(":latest") -or
    $newImage -eq $images.services.app.image) {
    throw "Supply a new published tag or digest to reliably refresh the app image."
}
$images.services.app.image = $newImage
$images | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $imagesPath -Encoding utf8
```

### U5. Deploy the update

```powershell
azd deploy
```

### U6. Get the application URL

```powershell
azd env get-value PUBLIC_URL
```

Do not delete the running container group just to refresh an image. For
infrastructure or hostname changes, run `azd provision` before `azd deploy` to
reconcile resources and Entra URLs.
