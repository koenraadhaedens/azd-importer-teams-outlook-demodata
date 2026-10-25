$ErrorActionPreference = "Stop"
foreach ($tool in @("az", "azd")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Install $tool; see README prerequisites."
    }
}
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 or later required by azd hooks." }
az account show --query id -o tsv | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run az login in the target tenant/subscription (also in OIDC CI)." }
az bicep version | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run az bicep install." }
if ($env:DEMO_TENANT_CONFIRMED -ne "true") {
    throw "Set azd env set DEMO_TENANT_CONFIRMED true only after confirming the isolated CDX tenant."
}
