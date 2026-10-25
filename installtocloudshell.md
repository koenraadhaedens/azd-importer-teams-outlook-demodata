# Install from Azure Cloud Shell

Open **PowerShell** in [Azure Cloud Shell](https://shell.azure.com/).
Tools and Azure CLI sign-in are assumed to be available.

This is a **fresh installation** using your already-published app image.
This walkthrough enables **real delivery** at deployment after mailbox-scope
verification. Running a reviewed executable scenario can send real demo mail
and Teams posts; inspect its dry run before explicitly starting execution.
Copy **one snippet at a time** and wait for completion. Resolve any reported
errors before continuing.
Keep the same shell open except when step 11 starts a clean Exchange session.

Before starting:

- Use an isolated CDX tenant and a subscription in that tenant.
- Your account needs Azure deployment rights and the Entra administrator rights
  described in [Entra setup](docs/entra-setup.md#deployment-identity-prerequisites).
- The published app must contain your correct five users and Teams mappings.
  The checkout used below must contain the same configuration.
- Both images in [container-images.json](config/container-images.json) must be
  published and anonymously pullable.

Provisioning creates the resource group and runtime managed identity; deployment
adds the ACI container group. No Key Vault, Log Analytics workspace or storage
account is provisioned. Read app and HTTPS logs with `az container logs` as shown
below; no centralized log retention is configured.

## 1. Clone and open the project

```powershell
git clone https://github.com/koenraadhaedens/azd-importer-teams-outlook-demodata.git
Set-Location azd-importer-teams-outlook-demodata
```

If you already have the checkout, enter that folder instead of cloning again.

## 2. Sign in to azd

Complete the sign-in with your CDX deployment account. Azure CLI and azd have
separate authentication.

```powershell
azd auth login --use-device-code
```

## 3. Prepare the demo settings

Only confirm this after verifying you are using the isolated CDX tenant.
Enter an email address for HTTPS certificate notices.
These process environment variables supply the provisioning hooks without
creating an azd environment yet. Keep this shell open through provisioning;
the settings are saved to the new azd environment afterward.

```powershell
$env:DEMO_TENANT_CONFIRMED = "true"
$env:ACME_EMAIL = Read-Host "Email for certificate notices"
$env:DELIVERY_ENABLED = "true"
$env:MAILBOX_SCOPE_CONFIRMED = "false"
```

## 4. Set yourself as the operator

```powershell
$operatorId = az ad signed-in-user show --query id --output tsv
if ([string]::IsNullOrWhiteSpace($operatorId)) {
    throw "Could not resolve the signed-in operator."
}
$operatorId = $operatorId.Trim()
$env:OPERATOR_IDS = $operatorId
```

## 5. Provision

For a fresh checkout with no selected environment, enter a new **environment
name** when `azd provision` prompts. Select your **subscription and location**
when prompted too; there is no separate `azd env new` step. Azure CLI must also
be authenticated in the same target tenant/subscription because the hooks use it.

```powershell
azd provision
```

Wait until provisioning succeeds. It creates the Azure resources, runtime Graph
grant, public hostname, and secretless web registration.
The app is intentionally dormant until the administrator steps below are done.
Do not use `azd up` to skip those steps.

After provisioning succeeds, save the prepared settings to the selected azd
environment so they remain available to later commands and new shell sessions:

```powershell
azd env set DEMO_TENANT_CONFIRMED $env:DEMO_TENANT_CONFIRMED
azd env set ACME_EMAIL $env:ACME_EMAIL
azd env set DELIVERY_ENABLED $env:DELIVERY_ENABLED
azd env set MAILBOX_SCOPE_CONFIRMED $env:MAILBOX_SCOPE_CONFIRMED
azd env set OPERATOR_IDS $env:OPERATOR_IDS
```

## 6. Read the generated IDs

```powershell
$webClientId = azd env get-value WEB_CLIENT_ID
$identityClientId = azd env get-value AZURE_IDENTITY_CLIENT_ID
$identityPrincipalId = azd env get-value AZURE_IDENTITY_PRINCIPAL_ID
$environmentName = azd env get-value AZURE_ENV_NAME
```

## 7. Read the five configured demo users

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

## 8. Install the administrator modules

These are additional modules used by the permission helpers, not Cloud Shell
deployment prerequisites.

```powershell
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser -Force
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
```

## 9. Resolve the users for application access

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

## 10. Assign users and grant Teams consent

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

## 11. Start a clean PowerShell process for Exchange

Graph and Exchange modules can load incompatible versions of shared assemblies.
After Graph setup, start a separate process so Exchange does not reuse those
assemblies. Removing a module does not unload its assemblies.

```powershell
pwsh -NoProfile
```

Wait for the new PowerShell prompt. It keeps the current directory, but not your
PowerShell variables. Do not load Microsoft Graph modules in this new process.

Reload the selected environment's runtime identity IDs and mailbox list:

```powershell
$identityClientId = azd env get-value AZURE_IDENTITY_CLIENT_ID
$identityPrincipalId = azd env get-value AZURE_IDENTITY_PRINCIPAL_ID
$environmentName = azd env get-value AZURE_ENV_NAME
$demoConfig = Get-Content -LiteralPath (Join-Path "config" "demo-users.json") -Raw |
    ConvertFrom-Json
$demoUpns = @($demoConfig.users | ForEach-Object { $_.userPrincipalName })
```

Enter an existing sixth mailbox that is **not** one of the five demo users:

```powershell
$outOfScopeTestUpn = Read-Host "Sixth mailbox UPN for the out-of-scope test"
```

## 12. Configure Exchange mailbox scope

Run in the clean process from step 11. Complete sign-in as your CDX Exchange
administrator. These parameters use the **runtime managed identity**, not the
web application.

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

Continue with step 13 in this clean process; no return to the Graph session is
needed.

### Recovering from an existing Exchange scope after a fresh deployment

Deleting the previous Azure resource group or running `azd down` does **not**
delete tenant-level Entra app registrations, enterprise applications, Exchange
service-principal registrations, management scopes, or role assignments.
A new azd environment/resource group is therefore not a completely clean
Microsoft 365 tenant.

If step 12 reports that an existing management scope has the same filter and
says **"Use the existing management scope instead of creating a new one"**:

- Do not delete the existing scope or rerun the helper with its name. The helper
  names assignments after the scope and does not verify an existing assignment's
  principal, so that alone does not grant the new identity access.
- Reuse the existing scope only if it selects exactly the configured five
  mailboxes. The new runtime managed identity still needs its own Exchange
  registration and `Application Mail.Send` assignment.
- This error does not establish whether the web app registration was reused.
  Check `azd env get-value WEB_CLIENT_ID`; Exchange uses the runtime identity IDs
  below, not that web client ID.

In the clean Exchange PowerShell process from step 11, select the intended
environment with `azd env list` / `azd env select <name>` if necessary, then run:

```powershell
$identityClientId = (azd env get-value AZURE_IDENTITY_CLIENT_ID).Trim()
$identityPrincipalId = (azd env get-value AZURE_IDENTITY_PRINCIPAL_ID).Trim()
$demoConfig = Get-Content -LiteralPath (Join-Path "config" "demo-users.json") -Raw |
    ConvertFrom-Json
$demoUpns = @($demoConfig.users | ForEach-Object { $_.userPrincipalName })
$outOfScopeTestUpn = Read-Host "Sixth mailbox UPN, not one of the five demo users"
$existingScopeName = Read-Host "Existing scope name reported by Exchange"

Connect-ExchangeOnline -ShowBanner:$false
$scope = Get-ManagementScope -Identity $existingScopeName
$expected = @($demoUpns | ForEach-Object {
    (Get-EXOMailbox -Identity $_).PrimarySmtpAddress.ToString().ToLowerInvariant()
} | Sort-Object -Unique)
$actual = @(Get-Recipient -RecipientPreviewFilter $scope.RecipientFilter -ResultSize Unlimited |
    ForEach-Object { $_.PrimarySmtpAddress.ToString().ToLowerInvariant() } |
    Sort-Object -Unique)
if ($expected.Count -ne 5 -or $actual.Count -ne 5 -or
    (Compare-Object -ReferenceObject $expected -DifferenceObject $actual)) {
    throw "Existing scope does not select exactly the configured five mailboxes; stop for review."
}
if ($outOfScopeTestUpn -in $demoUpns) {
    throw "The sixth test mailbox must not be a demo mailbox."
}
$null = Get-EXOMailbox -Identity $outOfScopeTestUpn

# The failed helper registers the runtime principal before attempting scope creation.
$principals = @(Get-ServicePrincipal | Where-Object { $_.AppId -eq $identityClientId })
if ($principals.Count -ne 1 -or
    [string]$principals[0].ObjectId -ne $identityPrincipalId) {
    throw "Exchange registration does not match the selected runtime identity; stop for review."
}

$assignmentName = "DemoMailSend-$identityPrincipalId"
if (Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue) {
    throw "This assignment already exists. Inspect it and run the authorization tests below."
}
New-ManagementRoleAssignment `
    -Name $assignmentName `
    -App ([guid]$identityPrincipalId) `
    -Role "Application Mail.Send" `
    -CustomResourceScope $existingScopeName
```

For example, if the error names `demodeploy6-FiveMailboxes`, enter that exact
existing name at the prompt, not the new environment's proposed scope name.
Do not remove old assignments or registrations without confirming that they
are retired and unused by other deployments.

Then verify authorization for the **new** runtime identity:

```powershell
foreach ($upn in $demoUpns) {
    Write-Host "Demo mailbox: $upn"
    Test-ServicePrincipalAuthorization -Identity $identityPrincipalId -Resource $upn |
        Format-Table
}
Write-Host "Excluded mailbox: $outOfScopeTestUpn"
Test-ServicePrincipalAuthorization `
    -Identity $identityPrincipalId `
    -Resource $outOfScopeTestUpn |
    Format-Table
```

Check `Application Mail.Send`: all five demo mailboxes must have `InScope = True`
and the sixth must have `InScope = False`. Allow permission propagation and
repeat the tests if needed. Review additive Exchange/Entra grants as in step 12.
Do not set `MAILBOX_SCOPE_CONFIRMED=true` until verification succeeds.
The Exchange grant itself needs no container rebuild or redeployment.
Continue with step 13 only after the mailbox authorization checks succeed.

## 13. Deploy the application

Only continue after step 12 confirms the five allowed mailboxes and the excluded
sixth mailbox. Real delivery is enabled for this installation; this does not
automatically execute any scenario.

```powershell
azd env set MAILBOX_SCOPE_CONFIRMED true
azd env set DELIVERY_ENABLED true
azd deploy
```

Wait for deployment, certificate issuance, and HTTPS readiness to succeed.

## 14. Open the application

```powershell
azd env get-value PUBLIC_URL
```

Open the displayed URL, sign in as the operator, verify the resolved
users/resources, and inspect a **successful dry run**.
Scenarios marked `dryRun: true` remain non-executable. To send real demo content,
use a reviewed scenario deliberately marked `dryRun: false`, preview it, and
explicitly confirm execution as the operator.
Each Teams author signs in separately to execute their own actions.

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
Older versions provisioned Key Vault and Log Analytics. Incremental provisioning
does not remove those existing resources; review and remove unused legacy
resources separately if minimizing ongoing cost. Preserve any required logs and
secrets, and respect legacy Key Vault retention/purge protection.

```powershell
azd deploy
```
