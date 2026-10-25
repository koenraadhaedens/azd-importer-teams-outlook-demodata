$ErrorActionPreference = "Stop"

function Invoke-Azure {
    param([string[]]$Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI operation failed: $($Arguments[0])" }
    return $result
}

$env:WEB_CLIENT_ID = (& azd env get-value WEB_CLIENT_ID).Trim()
if ($LASTEXITCODE -ne 0 -or -not $env:WEB_CLIENT_ID) {
    throw "WEB_CLIENT_ID is missing; run azd provision to register the managed-identity-backed web app."
}
foreach ($name in @("AZURE_RESOURCE_GROUP", "AZURE_IDENTITY_RESOURCE_ID", "AZURE_IDENTITY_CLIENT_ID",
    "JOURNAL_BLOB_URL", "ACI_NAME", "ACI_DNS_LABEL",
    "AZURE_LOG_WORKSPACE_NAME", "AZURE_CERT_STORAGE_NAME", "PUBLIC_HOSTNAME", "ACME_EMAIL", "WEB_CLIENT_ID",
    "OPERATOR_IDS", "AZURE_TENANT_ID")) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing azd environment value: $name" }
}
if ($env:PUBLIC_HOSTNAME -notmatch '^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw "PUBLIC_HOSTNAME must be an administrator-controlled public DNS hostname."
}
if ($env:ACME_EMAIL -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
    throw "ACME_EMAIL must be a valid administrative email address."
}
if ($env:DEMO_TENANT_CONFIRMED -ne "true") { throw "Isolated demo tenant confirmation is required." }
$null = [guid]::Parse($env:WEB_CLIENT_ID)
$null = [guid]::Parse($env:AZURE_TENANT_ID)
$ids = @($env:OPERATOR_IDS | ConvertFrom-Json)
foreach ($id in $ids) { $null = [guid]::Parse($id) }

# Bicep reads both pre-published image references from config/container-images.json.
# Deployment never builds, pushes, retags or resolves images through the deployer's credentials.

$parameters = @{
    containerGroupName = @{ value = $env:ACI_NAME }
    dnsLabel = @{ value = $env:ACI_DNS_LABEL }
    publicHostname = @{ value = $env:PUBLIC_HOSTNAME }
    acmeEmail = @{ value = $env:ACME_EMAIL }
    identityResourceId = @{ value = $env:AZURE_IDENTITY_RESOURCE_ID }
    identityClientId = @{ value = $env:AZURE_IDENTITY_CLIENT_ID }
    tenantId = @{ value = $env:AZURE_TENANT_ID }
    webClientId = @{ value = $env:WEB_CLIENT_ID }
    journalBlobUrl = @{ value = $env:JOURNAL_BLOB_URL }
    logWorkspaceName = @{ value = $env:AZURE_LOG_WORKSPACE_NAME }
    certificateStorageName = @{ value = $env:AZURE_CERT_STORAGE_NAME }
    operatorIds = @{ value = $env:OPERATOR_IDS }
    authorizedGroupId = @{ value = $(if ($env:AUTHORIZED_GROUP_ID) { $env:AUTHORIZED_GROUP_ID } else { "" }) }
    deliveryEnabled = @{ value = ($env:DELIVERY_ENABLED -eq "true") }
    mailboxScopeConfirmed = @{ value = ($env:MAILBOX_SCOPE_CONFIRMED -eq "true") }
    allowExternalRecipients = @{ value = ($env:ALLOW_EXTERNAL_RECIPIENTS -eq "true") }
}
$file = Join-Path ([IO.Path]::GetTempPath()) ("aci-" + [guid]::NewGuid().ToString() + ".json")
try {
    @{ '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#";
        contentVersion = "1.0.0.0"; parameters = $parameters
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $file
    Invoke-Azure @("deployment", "group", "create", "--resource-group", $env:AZURE_RESOURCE_GROUP,
        "--name", "aci-app", "--template-file", "infra/aci.bicep", "--parameters", "@$file") | Out-Host
} finally {
    Remove-Item -LiteralPath $file -Force
}
$fqdn = (Invoke-Azure @("container", "show", "-g", $env:AZURE_RESOURCE_GROUP, "-n", $env:ACI_NAME,
    "--query", "ipAddress.fqdn", "-o", "tsv")).Trim()
Write-Host "DNS prerequisite: CNAME $($env:PUBLIC_HOSTNAME) -> $fqdn"
Write-Host "Verify HTTPS readiness; DNS propagation and administrator consent may still be required."
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    try {
        $response = Invoke-WebRequest "https://$($env:PUBLIC_HOSTNAME)/healthz" -TimeoutSec 10
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch {
        Write-Warning "HTTPS readiness not yet confirmed (attempt $($i + 1)/12)."
    }
    Start-Sleep -Seconds 10
}
if (-not $ready) { throw "HTTPS readiness failed. Check DNS, runtime Graph roles and managed-identity trust; see troubleshooting." }
