param(
    [Parameter(Mandatory)][ValidateSet("Provision", "Entra", "Exchange", "Deploy")][string]$Stage,
    [string]$Config = (Join-Path (Join-Path $PSScriptRoot "..") "config/config.json"),
    [switch]$ConfirmDemoTenant,
    [switch]$ConfirmMailboxScope,
    [switch]$InstallModules
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 or later is required." }
$configPath = (Resolve-Path -LiteralPath $Config -ErrorAction Stop).Path
$configuration = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop
$demoUpns = @($configuration.'x-demo'.users | ForEach-Object {
    [string]$_.userPrincipalName
})
if ($demoUpns.Count -ne 5 -or
    @($demoUpns | Where-Object { $_ -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$' }).Count -gt 0 -or
    @($demoUpns | Sort-Object -Unique).Count -ne 5) {
    throw "Configure exactly five distinct demo-user UPNs in x-demo.users."
}
$acmeEmail = [string]$configuration.'x-setup'.acmeEmail
if ($acmeEmail -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
    throw "Configure x-setup.acmeEmail in $configPath for certificate notices."
}
$excludedUpn = [string]$configuration.'x-setup'.outOfScopeTestUpn
if ($excludedUpn -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$' -or $excludedUpn -in $demoUpns) {
    throw "Configure x-setup.outOfScopeTestUpn as an existing sixth mailbox, not a demo user."
}

function Invoke-SetupAzd {
    param([string[]]$Arguments)
    $result = & azd @Arguments
    if ($LASTEXITCODE -ne 0) { throw "azd $($Arguments -join ' ') failed; resolve the error before continuing." }
    return $result
}

function Get-SetupValue {
    param([string]$Name)
    $value = ((Invoke-SetupAzd @("env", "get-value", $Name)) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing $Name; select the correct environment and run the Provision stage." }
    return $value
}

function Get-SetupUserId {
    param([string]$Upn)
    $arguments = @("ad", "user", "show", "--id", $Upn, "--query", "id", "--output", "tsv")
    if ($script:subscriptionId) { $arguments += @("--subscription", $script:subscriptionId) }
    $result = & az @arguments
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve Entra user: $Upn" }
    return ([guid]::Parse(($result -join "").Trim())).ToString()
}

function Install-SetupModule {
    param([string]$Name)
    if (-not (Get-Module $Name -ListAvailable)) {
        if (-not $InstallModules) { throw "Missing $Name. Rerun this stage with -InstallModules to install it for the current user." }
        Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
    }
}

Push-Location (Join-Path $PSScriptRoot "..")
try {
    if ($Stage -eq "Provision") {
        if (-not $ConfirmDemoTenant) {
            throw "Verify the isolated CDX tenant/subscription, then rerun with -ConfirmDemoTenant."
        }
        $operator = & az ad signed-in-user show --query id --output tsv
        if ($LASTEXITCODE -ne 0) { throw "Could not resolve the signed-in operator; authenticate Azure CLI in the demo tenant." }
        $env:OPERATOR_IDS = ([guid]::Parse(($operator -join "").Trim())).ToString()
        $env:ACME_EMAIL = $acmeEmail
        $env:DEMO_TENANT_CONFIRMED = "true"
        $env:DELIVERY_ENABLED = "false"
        $env:MAILBOX_SCOPE_CONFIRMED = "false"
        Invoke-SetupAzd @("provision") | Out-Host
        foreach ($name in @("OPERATOR_IDS", "ACME_EMAIL", "DEMO_TENANT_CONFIRMED",
            "DELIVERY_ENABLED", "MAILBOX_SCOPE_CONFIRMED")) {
            Invoke-SetupAzd @("env", "set", $name, [Environment]::GetEnvironmentVariable($name)) | Out-Host
        }
        Write-Host "Provisioned with delivery disabled. Next: run the Entra stage in a clean PowerShell process."
        return
    }

    $script:subscriptionId = Get-SetupValue "AZURE_SUBSCRIPTION_ID"
    $tenantId = [guid](Get-SetupValue "AZURE_TENANT_ID")
    $tenant = & az account show --subscription $script:subscriptionId --query tenantId --output tsv
    if ($LASTEXITCODE -ne 0 -or ($tenant -join "").Trim() -ne $tenantId.ToString()) {
        throw "Azure CLI must be authenticated in the selected azd environment's tenant/subscription."
    }
    if ($Stage -eq "Entra") {
        Install-SetupModule "Microsoft.Graph.Applications"
        Install-SetupModule "Microsoft.Graph.Identity.SignIns"
        $env:OPERATOR_IDS = Get-SetupValue "OPERATOR_IDS"
        . (Join-Path $PSScriptRoot "aci-deployment.ps1")
        $allowedIds = @((Get-OperatorIdsJson | ConvertFrom-Json)) +
            @($demoUpns | ForEach-Object { Get-SetupUserId $_ })
        & (Join-Path $PSScriptRoot "setup-entra.ps1") `
            -WebClientId ([guid](Get-SetupValue "WEB_CLIENT_ID")) `
            -AllowedObjectIds @($allowedIds | Sort-Object -Unique) -GrantConsent
        Write-Host "Next: run the Exchange stage in a separate clean PowerShell process."
    } elseif ($Stage -eq "Exchange") {
        if (Get-Module Microsoft.Graph.*) {
            throw "Run Exchange in a clean process: pwsh -NoProfile -File scripts/setup.ps1 -Stage Exchange"
        }
        Install-SetupModule "ExchangeOnlineManagement"
        & (Join-Path $PSScriptRoot "setup-exchange.ps1") `
            -ApplicationId ([guid](Get-SetupValue "AZURE_IDENTITY_CLIENT_ID")) `
            -PrincipalObjectId ([guid](Get-SetupValue "AZURE_IDENTITY_PRINCIPAL_ID")) `
            -DemoUpns $demoUpns -OutOfScopeTestUpn $excludedUpn `
            -ScopeName "$(Get-SetupValue 'AZURE_ENV_NAME')-FiveMailboxes"
        Write-Host "Review all six results and additive grants before running Deploy -ConfirmMailboxScope."
    } else {
        if (-not $ConfirmMailboxScope) {
            throw "Review five InScope=True results, the sixth InScope=False, and additive grants; then rerun with -ConfirmMailboxScope."
        }
        if ((Get-SetupValue "DEMO_TENANT_CONFIRMED") -ne "true") {
            throw "The selected environment must have DEMO_TENANT_CONFIRMED=true."
        }
        Invoke-SetupAzd @("env", "set", "ACME_EMAIL", $acmeEmail) | Out-Host
        Invoke-SetupAzd @("env", "set", "MAILBOX_SCOPE_CONFIRMED", "true") | Out-Host
        Invoke-SetupAzd @("env", "set", "DELIVERY_ENABLED", "true") | Out-Host
        Invoke-SetupAzd @("deploy") | Out-Host
        Write-Host "Application URL: $(Get-SetupValue 'PUBLIC_URL')"
    }
} finally {
    Pop-Location
}
