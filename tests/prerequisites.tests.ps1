$ErrorActionPreference = "Stop"
$previousConfirmation = $env:DEMO_TENANT_CONFIRMED
$previousOperators = $env:OPERATOR_IDS
$previousEmail = $env:ACME_EMAIL
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
        @{ name = "new environment missing both settings"; missingOperators = $true; missingEmail = $true; installs = 0; checks = 0; error = "Missing azd environment values: OPERATOR_IDS, ACME_EMAIL." }
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
        $env:ACME_EMAIL = if ($case.missingEmail) { " " } else { "operator@example.org" }
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
} finally {
    $env:DEMO_TENANT_CONFIRMED = $previousConfirmation
    $env:OPERATOR_IDS = $previousOperators
    $env:ACME_EMAIL = $previousEmail
    Remove-Item Function:\az, Function:\azd
    Remove-Variable prerequisiteMock -Scope Global
}
