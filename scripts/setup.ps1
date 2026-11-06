param(
    [ValidateSet("Install", "Configure", "Provision", "Entra", "Exchange", "Deploy")][string]$Stage = "Install",
    [string]$Config,
    [switch]$ConfirmDemoTenant,
    [switch]$ConfirmMailboxScope,
    [switch]$InstallModules
)
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
if ($PSVersionTable.PSVersion.Major -lt 7) { throw "PowerShell 7 or later is required." }
. (Join-Path $PSScriptRoot "deployment-config.ps1")
if (-not $Config) {
    $Config = if ($env:DEMO_CONFIG_FILE) { $env:DEMO_CONFIG_FILE } else {
        Join-Path (Join-Path $PSScriptRoot "..") "config/config.local.json"
    }
}
$configPath = [IO.Path]::GetFullPath($Config)
if ($Stage -eq "Install") {
    function Invoke-SetupStage {
        param([string]$Name, [string[]]$Arguments)
        Write-Host "Setup: $Name"
        & pwsh -NoProfile -File $PSCommandPath -Stage $Name -Config $configPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Setup stopped at $Name. Resolve the error, then retry: pwsh -NoProfile -File `"$PSCommandPath`" -Stage $Name -Config `"$configPath`" $($Arguments -join ' ')"
        }
    }

    Invoke-SetupStage "Configure"
    & az account show --query "{subscription:name,tenantId:tenantId}" --output table
    if ($LASTEXITCODE -ne 0) { throw "Authenticate Azure CLI in your demo tenant before continuing." }
    if (-not $ConfirmDemoTenant -and
        (Read-Host "Type YES to confirm this is your isolated demo tenant/subscription") -ne "YES") {
        throw "Setup cancelled before provisioning."
    }
    Invoke-SetupStage "Provision" @("-ConfirmDemoTenant")
    Invoke-SetupStage "Entra" @("-InstallModules")
    Invoke-SetupStage "Exchange" @("-InstallModules")
    Write-Host "Review the Exchange results: five mailboxes InScope=True, the sixth InScope=False, and no other grants broadening access."
    if (-not $ConfirmMailboxScope -and
        (Read-Host "Type YES to confirm mailbox access is correct and enable demo delivery") -ne "YES") {
        throw "Delivery remains disabled. After reviewing mailbox access, continue with -Stage Deploy -ConfirmMailboxScope."
    }
    Invoke-SetupStage "Deploy" @("-ConfirmMailboxScope")
    return
}
if ($Stage -eq "Configure" -or ($Stage -eq "Provision" -and -not (Test-Path -LiteralPath $configPath))) {
    $template = Join-Path (Join-Path $PSScriptRoot "..") "config/config.json"
    if ($configPath -eq [IO.Path]::GetFullPath($template)) { throw "Do not store trainer settings in the tracked template." }
    if (-not (Test-Path -LiteralPath $configPath)) {
        $configuration = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
        $directory = Split-Path -Parent $configPath
        $null = New-Item -ItemType Directory -Path $directory -Force
        Write-PrivateJsonFile -Path $configPath -Value $configuration
    }
    Write-Host "Upload your configuration to this path, or edit the file there: $configPath"
    Write-Host "Set x-setup, the five x-demo.users, optional x-demo.channels, and published services image references."
    Write-Host "Keep this local file private. Do not commit or share it, or edit the tracked config/config.json template."
    $null = Read-Host "Press Enter after uploading or saving the file to continue"
    $null = Read-DeploymentConfiguration -Path $configPath
    Write-Host "Private configuration validated. Subsequent stages will use this file."
    if ($Stage -eq "Configure") { return }
}
$configuration = Read-DeploymentConfiguration -Path $configPath
$env:DEMO_CONFIG_FILE = $configPath
$demoUpns = @($configuration.'x-demo'.users.userPrincipalName)
$acmeEmail = [string]$configuration.'x-setup'.acmeEmail
$excludedUpn = [string]$configuration.'x-setup'.outOfScopeTestUpn

function Invoke-SetupAzd {
    param([string[]]$Arguments)
    & azd @Arguments
    if ($LASTEXITCODE -ne 0) { throw "azd $($Arguments -join ' ') failed; resolve the error before continuing." }
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
        Invoke-SetupAzd @("provision")
        foreach ($name in @("OPERATOR_IDS", "DEMO_CONFIG_FILE", "DEMO_TENANT_CONFIRMED",
            "DELIVERY_ENABLED", "MAILBOX_SCOPE_CONFIRMED")) {
            Invoke-SetupAzd @("env", "set", $name, [Environment]::GetEnvironmentVariable($name)) | Out-Host
        }
        Write-Host "Provisioning complete; delivery is disabled."
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
        Write-Host "Entra user assignments and consent complete."
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
        Invoke-SetupAzd @("env", "set", "DEMO_CONFIG_FILE", $configPath) | Out-Host
        Invoke-SetupAzd @("env", "set", "MAILBOX_SCOPE_CONFIRMED", "true") | Out-Host
        Invoke-SetupAzd @("env", "set", "DELIVERY_ENABLED", "true") | Out-Host
        Invoke-SetupAzd @("deploy")
        Write-Host "Application URL: $(Get-SetupValue 'PUBLIC_URL')"
    }
} finally {
    Pop-Location
}
