$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
foreach ($tool in @("az", "azd")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Install $tool; see README prerequisites."
    }
}
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 or later required by azd hooks." }
az account show --query id -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run az login in the target tenant/subscription (also in OIDC CI)." }
if ($env:DEMO_TENANT_CONFIRMED -ne "true") {
    throw "Set azd env set DEMO_TENANT_CONFIRMED true only after confirming the isolated CDX tenant."
}
$missing = @("OPERATOR_IDS", "ACME_EMAIL") | Where-Object {
    [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
}
if ($missing) {
    throw "Missing azd environment values: $($missing -join ', '). Settings belong to the selected azd environment. Configure them with azd env set before provisioning; see README deployment setup."
}
az bicep version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Bicep CLI is unavailable. Installing with Azure CLI for the current user..."
    az bicep install --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep installation failed. Check outbound network access and write access to the Azure CLI configuration directory, then run az bicep install and retry azd provision."
    }
    az bicep version | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Bicep is still unavailable after installation. Check az config get bicep.use_binary_from_path and the Azure CLI installation, then retry azd provision."
    }
}
