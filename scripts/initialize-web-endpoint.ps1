$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "aci-deployment.ps1")
if (-not $env:AZURE_RESOURCE_GROUP -or -not $env:ACI_NAME) {
    throw "Provision supporting resources before initializing the ACI endpoint."
}
if (-not $env:AZURE_TENANT_ID) {
    throw "AZURE_TENANT_ID is missing from the azd environment. Rerun azd provision with the current infrastructure template to export the selected subscription's tenant ID."
}
$expectedTenant = [guid]::Empty
if (-not [guid]::TryParse($env:AZURE_TENANT_ID, [ref]$expectedTenant)) {
    throw "AZURE_TENANT_ID must be a valid tenant GUID. Check the selected subscription and azd environment."
}
$tenant = Invoke-Azure @("account", "show", "--query", "tenantId", "--output", "tsv", "--only-show-errors")
if (([string]$tenant).Trim() -ne $expectedTenant.ToString()) {
    throw "Azure CLI tenant '$(([string]$tenant).Trim())' does not match provisioned AZURE_TENANT_ID '$expectedTenant'. Authenticate Azure CLI in the target tenant/subscription before ACI initialization."
}
$container = Get-AciContainer
if ($null -eq $container -or -not $container.ipAddress.fqdn) {
    Write-Host "Creating ACI in initialization mode to obtain its actual Azure DNS hostname."
    # Same images/topology as the final group; no app startup, Graph writes or certificate requests.
    Invoke-AciDeployment -Bootstrap
}
$env:PUBLIC_HOSTNAME = Get-AciHostname
$env:PUBLIC_URL = "https://$($env:PUBLIC_HOSTNAME)"
foreach ($name in @("PUBLIC_HOSTNAME", "PUBLIC_URL")) {
    & azd env set $name ([Environment]::GetEnvironmentVariable($name))
    if ($LASTEXITCODE -ne 0) { throw "Could not save the discovered $name in azd." }
}
& (Join-Path $PSScriptRoot "register-web-app.ps1") -PublicHostname $env:PUBLIC_HOSTNAME
Write-Host "Discovered endpoint: $($env:PUBLIC_URL). Run azd deploy after administrator consent/assignments and runtime grants."
