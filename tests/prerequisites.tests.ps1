$ErrorActionPreference = "Stop"
$previousConfirmation = $env:DEMO_TENANT_CONFIRMED
$previousOperators = $env:OPERATOR_IDS
$previousEmail = $env:ACME_EMAIL
$previousImagePull = $env:USE_MANAGED_IDENTITY_FOR_IMAGE_PULL
$previousConfigFile = $env:DEMO_CONFIG_FILE
$env:DEMO_CONFIG_FILE = ""
$privateConfig = Join-Path ([IO.Path]::GetTempPath()) ("prerequisite-" + [guid]::NewGuid() + ".json")
$exampleOperatorId = [guid]::NewGuid().ToString()
$global:prerequisiteMock = @{}
function global:azd {}
function global:az {
    $state = $global:prerequisiteMock
    $global:LASTEXITCODE = 0
    if ($args[0] -eq "account") {
        if ($state.loginFails) { $global:LASTEXITCODE = 1 }
        return
    }
    if ($args[0] -eq "bicep" -and $args[1] -eq "version") {
        $state.versionChecks++
        if (-not $state.installed -or $state.verificationFails) {
            $global:LASTEXITCODE = 1
        } else {
            return "Bicep CLI version test"
        }
        return
    }
    if ($args[0] -eq "bicep" -and $args[1] -eq "install") {
        $state.installCalls++
        if ($state.installFails) {
            $global:LASTEXITCODE = 1
        } else {
            $state.installed = $true
        }
        return
    }
    throw "Unexpected Azure CLI operation: $args"
}
try {
    foreach ($case in @(
        @{ name = "existing Bicep"; installed = $true; installs = 0; checks = 1 },
        @{ name = "Cloud Shell missing Bicep"; installs = 1; checks = 2 },
        @{ name = "installation fails"; installFails = $true; installs = 1; checks = 1; error = "Bicep installation failed" },
        @{ name = "verification fails"; verificationFails = $true; installs = 1; checks = 2; error = "Bicep is still unavailable" },
        @{ name = "login absent"; loginFails = $true; installs = 0; checks = 0; error = "Run az login" },
        @{ name = "demo tenant not confirmed"; unconfirmed = $true; installs = 0; checks = 0; error = "DEMO_TENANT_CONFIRMED" },
        @{ name = "operators missing"; missingOperators = $true; installs = 0; checks = 0; error = "Missing azd environment values: OPERATOR_IDS." },
        @{ name = "ACME email missing"; missingEmail = $true; installs = 0; checks = 0; error = "Missing azd environment values: ACME_EMAIL." },
        @{ name = "new environment missing both settings"; missingOperators = $true; missingEmail = $true; installs = 0; checks = 0; error = "Missing azd environment values: OPERATOR_IDS, ACME_EMAIL." },
        @{ name = "single operator GUID"; operators = $exampleOperatorId; installed = $true; installs = 0; checks = 1 },
        @{ name = "malformed operator JSON"; operators = "[$exampleOperatorId]"; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "non-GUID operator"; operators = '["not-a-guid"]'; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "JSON null rejected"; operators = "null"; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "JSON object rejected"; operators = "{}"; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "JSON string rejected"; operators = '"' + $exampleOperatorId + '"'; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "non-string array member rejected"; operators = "[42]"; installs = 0; checks = 0; error = "OPERATOR_IDS must be one Entra user object ID GUID" },
        @{ name = "explicit anonymous image pulls"; imagePull = "false"; installed = $true; installs = 0; checks = 1 },
        @{ name = "opt-in managed identity image pulls"; imagePull = "true"; installed = $true; installs = 0; checks = 1 },
        @{ name = "invalid image pull flag"; imagePull = "invalid"; installs = 0; checks = 0; error = "USE_MANAGED_IDENTITY_FOR_IMAGE_PULL must be true or false" }
    )) {
        $global:prerequisiteMock = @{
            installed = [bool]$case.installed
            loginFails = [bool]$case.loginFails
            installFails = [bool]$case.installFails
            verificationFails = [bool]$case.verificationFails
            installCalls = 0
            versionChecks = 0
        }
        $env:DEMO_TENANT_CONFIRMED = if ($case.unconfirmed) { "false" } else { "true" }
        $env:OPERATOR_IDS = if ($case.missingOperators) { "" } else { '["' + [guid]::NewGuid().ToString() + '"]' }
        if ($case.operators) { $env:OPERATOR_IDS = $case.operators }
        $env:ACME_EMAIL = if ($case.missingEmail) { " " } else { "operator@example.org" }
        $env:USE_MANAGED_IDENTITY_FOR_IMAGE_PULL = $case.imagePull
        $failure = $null
        try {
            & (Join-Path $PSScriptRoot "../scripts/prerequisites.ps1")
        } catch {
            $failure = $_.Exception.Message
        }
        if ($case.error) {
            if (-not $failure -or -not $failure.Contains($case.error)) {
                throw "$($case.name): expected '$($case.error)', received '$failure'."
            }
        } elseif ($failure) {
            throw "$($case.name): $failure"
        }
        if ($global:prerequisiteMock.installCalls -ne $case.installs -or
            $global:prerequisiteMock.versionChecks -ne $case.checks) {
            throw "$($case.name): incorrect Bicep install/version invocation counts."
        }
        if (-not $case.error -and $case.installs -eq 1) {
            & (Join-Path $PSScriptRoot "../scripts/prerequisites.ps1")
            if ($global:prerequisiteMock.installCalls -ne 1) {
                throw "A rerun must reuse Bicep, not reinstall it."
            }
        }
        Write-Host "PASS: $($case.name)"
    }
    . (Join-Path (Join-Path $PSScriptRoot "..") "scripts/deployment-config.ps1")
    Write-PrivateJsonFile -Path $privateConfig -Value @{
        services = @{
            app = @{ image = "example.azurecr.io/app:test" }
            caddy = @{ image = "example.azurecr.io/caddy:test" }
        }
        "x-setup" = @{ acmeEmail = "notices@example.org"; outOfScopeTestUpn = "excluded@example.org" }
        "x-demo" = @{
            users = @((1..5) | ForEach-Object {
                @{ key = "user$_"; displayName = "User $_"; userPrincipalName = "user$_@example.org" }
            })
            channels = @{}
        }
    }
    $env:DEMO_CONFIG_FILE = $privateConfig
    $env:ACME_EMAIL = ""
    $env:OPERATOR_IDS = $exampleOperatorId
    $env:DEMO_TENANT_CONFIRMED = "true"
    $env:USE_MANAGED_IDENTITY_FOR_IMAGE_PULL = ""
    $global:prerequisiteMock = @{ installed = $true; versionChecks = 0; installCalls = 0 }
    & (Join-Path $PSScriptRoot "../scripts/prerequisites.ps1")
    if ($env:ACME_EMAIL -ne "notices@example.org" -or $global:prerequisiteMock.versionChecks -ne 1) {
        throw "Preprovision must obtain certificate email privately from the configured file."
    }
    Write-Host "PASS: private configuration supplies certificate email without azd setting arguments"
} finally {
    $env:DEMO_TENANT_CONFIRMED = $previousConfirmation
    $env:OPERATOR_IDS = $previousOperators
    $env:ACME_EMAIL = $previousEmail
    $env:USE_MANAGED_IDENTITY_FOR_IMAGE_PULL = $previousImagePull
    $env:DEMO_CONFIG_FILE = $previousConfigFile
    if (Test-Path -LiteralPath $privateConfig) { Remove-Item -LiteralPath $privateConfig }
    Remove-Item Function:\az, Function:\azd
    Remove-Variable prerequisiteMock -Scope Global
}
