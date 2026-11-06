$ErrorActionPreference = "Stop"
$scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "scripts/setup.ps1"
$configPath = Join-Path ([IO.Path]::GetTempPath()) ("setup-test-" + [guid]::NewGuid() + ".json")
$savedEnvironment = @{}
foreach ($name in @("OPERATOR_IDS", "ACME_EMAIL", "DEMO_TENANT_CONFIRMED",
    "DELIVERY_ENABLED", "MAILBOX_SCOPE_CONFIRMED", "DEMO_CONFIG_FILE")) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-TestConfig {
    param([string]$Email = "notices@example.org", [string]$Excluded = "excluded@example.org")
    @{
        services = @{
            app = @{ image = "example.azurecr.io/app:latest" }
            caddy = @{ image = "example.azurecr.io/caddy:latest" }
        }
        "x-setup" = @{ acmeEmail = $Email; outOfScopeTestUpn = $Excluded }
        "x-demo" = @{
            channels = @{}
            users = @((1..5) | ForEach-Object {
                @{ key = "user$_"; displayName = "User $_"; userPrincipalName = "user$_@example.org" }
            })
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath
}
function Reset-State {
    $global:setupMock = @{
        calls = [System.Collections.Generic.List[object]]::new()
        provisionFails = $false
        valueFails = $false
        values = @{
            AZURE_SUBSCRIPTION_ID = [guid]::NewGuid().ToString()
            AZURE_TENANT_ID = [guid]::NewGuid().ToString()
            DEMO_TENANT_CONFIRMED = "true"
            PUBLIC_URL = "https://demo.example.org"
            WEB_CLIENT_ID = [guid]::NewGuid().ToString()
            AZURE_IDENTITY_CLIENT_ID = [guid]::NewGuid().ToString()
            AZURE_IDENTITY_PRINCIPAL_ID = [guid]::NewGuid().ToString()
            AZURE_ENV_NAME = "configured-demo"
            OPERATOR_IDS = "00000000-0000-0000-0000-000000000001"
        }
        assigned = [System.Collections.Generic.List[string]]::new()
        tested = [System.Collections.Generic.List[string]]::new()
        exchangePrincipal = $null
        prompts = [System.Collections.Generic.Queue[string]]::new()
        onConfirm = $null
        stages = [System.Collections.Generic.List[object]]::new()
        failedStage = ""
        streamProgress = $false
        progressReceived = $false
    }
    Write-TestConfig
}
function Expect-Failure {
    param([hashtable]$Parameters, [string]$Message)
    $failure = $null
    try { & $scriptPath -Config $configPath @Parameters | Out-Null } catch {
        $failure = $_.Exception.Message
    }
    Assert ($failure -and $failure.Contains($Message)) "Expected '$Message', received '$failure'"
}
function global:az {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq "ad" -and $args[1] -eq "signed-in-user") {
        return "00000000-0000-0000-0000-000000000001"
    }
    if ($args[0] -eq "account") { return $global:setupMock.values.AZURE_TENANT_ID }
    if ($args[0] -eq "ad" -and $args[1] -eq "user") {
        Assert ("--subscription" -notin $args) "Entra user lookup must not pass the unsupported --subscription argument"
        Assert ($args[4] -match '^user([1-5])@example.org$') "Only the five demo users should be assigned"
        return "00000000-0000-0000-0000-00000000001$($Matches[1])"
    }
    throw "Unexpected Azure call: $args"
}
function global:azd {
    $state = $global:setupMock
    $state.calls.Add(@($args))
    $global:LASTEXITCODE = 0
    if ($state.streamProgress -and $args[0] -in @("provision", "deploy")) {
        Write-Output "setup-progress:$($args[0])"
        Assert $state.progressReceived "Show azd output before the command finishes, not after it returns"
    }
    if ($args[0] -eq "provision") {
        Assert ($env:ACME_EMAIL -eq "notices@example.org") "Provision must read the configured certificate email"
        Assert ($env:DELIVERY_ENABLED -eq "false" -and $env:MAILBOX_SCOPE_CONFIRMED -eq "false") "Provision must disable real delivery"
        if ($state.provisionFails) { $global:LASTEXITCODE = 1 }
    } elseif ($args[0] -eq "env" -and $args[1] -eq "get-value") {
        if ($state.valueFails) { $global:LASTEXITCODE = 1; return }
        if (-not $state.values.ContainsKey([string]$args[2])) { throw "Unexpected azd value: $($args[2])" }
        return $state.values[[string]$args[2]]
    } elseif ($args[0] -eq "env" -and $args[1] -eq "set") {
        Assert ($args[2] -ne "ACME_EMAIL") "Keep certificate email out of azd command arguments and saved environment values"
        $state.values[[string]$args[2]] = [string]$args[3]
    } elseif ($args[0] -eq "deploy") {
        $configuration = Get-Content -LiteralPath $env:DEMO_CONFIG_FILE -Raw | ConvertFrom-Json
        Assert ($configuration.'x-setup'.acmeEmail -eq "notices@example.org") "Deploy must read private settings via the saved file path"
        Assert ($state.values.MAILBOX_SCOPE_CONFIRMED -eq "true" -and $state.values.DELIVERY_ENABLED -eq "true") "Delivery requires explicit confirmation"
    } else { throw "Unexpected azd call: $args" }
}
function global:Read-Host {
    param([string]$Prompt)
    Assert ($Prompt -in @(
        "Press Enter after uploading or saving the file to continue",
        "Type YES to confirm this is your isolated demo tenant/subscription",
        "Type YES to confirm mailbox access is correct and enable demo delivery"
    )) "Setup must not prompt for individual settings"
    if ($global:setupMock.prompts.Count -eq 0) { throw "Unexpected interactive prompt: $Prompt" }
    if ($global:setupMock.onConfirm) {
        Assert ($global:setupMock.calls.Count -eq 0) "Setup must pause before Azure operations"
        & $global:setupMock.onConfirm
    }
    return $global:setupMock.prompts.Dequeue()
}
function global:pwsh {
    param([switch]$NoProfile, [string]$File, [string]$Stage, [string]$Config,
        [Parameter(ValueFromRemainingArguments)][string[]]$StageArguments)
    Assert ($NoProfile -and [IO.Path]::GetFullPath($File) -eq [IO.Path]::GetFullPath($scriptPath)) "Run setup stages in clean PowerShell processes"
    Assert ($Config -eq $configPath) "Pass the selected private config path to every stage"
    $global:setupMock.stages.Add($Stage)
    $global:LASTEXITCODE = 0
    if ($global:setupMock.failedStage -eq $Stage) {
        $global:LASTEXITCODE = 1
        return
    }
    if ($Stage -eq "Configure") { & $File -Stage Configure -Config $Config }
    if ($Stage -in @("Entra", "Exchange")) {
        Assert ("-InstallModules" -in $StageArguments) "Install required administrator modules automatically"
    }
    if ($Stage -eq "Provision") { Assert ("-ConfirmDemoTenant" -in $StageArguments) "Pass tenant confirmation after operator approval" }
    if ($Stage -eq "Deploy") {
        Assert ("-ConfirmMailboxScope" -in $StageArguments) "Enable delivery only after mailbox-access approval"
        Assert ($global:setupMock.prompts.Count -eq 0) "Consume both approvals before deployment"
    }
}
function global:Get-Module {
    param($Name, [switch]$ListAvailable)
    if ($ListAvailable) { return @{ Name = $Name } }
}
function global:Connect-MgGraph { param($Scopes, [switch]$NoWelcome) }
function global:Get-MgServicePrincipal {
    param($Filter)
    return [pscustomobject]@{ Id = "test-principal"; AppRoleAssignmentRequired = $true }
}
function global:Get-MgServicePrincipalAppRoleAssignedTo { param($ServicePrincipalId, [switch]$All) }
function global:New-MgServicePrincipalAppRoleAssignedTo {
    param($ServicePrincipalId, $BodyParameter)
    $global:setupMock.assigned.Add([string]$BodyParameter.PrincipalId)
}
function global:Get-MgOauth2PermissionGrant { param($Filter) }
function global:New-MgOauth2PermissionGrant { param($BodyParameter) }
function global:Connect-ExchangeOnline { param([bool]$ShowBanner) }
function global:Get-EXOMailbox {
    param($Identity)
    return [pscustomobject]@{ PrimarySmtpAddress = [string]$Identity }
}
function global:Get-ServicePrincipal {}
function global:New-ServicePrincipal {
    param($AppId, $ObjectId, $DisplayName)
    $global:setupMock.exchangePrincipal = @{ AppId = $AppId; ObjectId = $ObjectId }
}
function global:Get-ManagementScope {}
function global:New-ManagementScope {
    [CmdletBinding()]
    param($Name, $RecipientRestrictionFilter)
    return [pscustomobject]@{ Name = $Name; RecipientFilter = $RecipientRestrictionFilter }
}
function global:Get-ManagementRoleAssignment {
    [CmdletBinding()]
    param($Identity, $RoleAssignee)
}
function global:New-ManagementRoleAssignment {
    [CmdletBinding()]
    param($Name, $App, $Role, $CustomResourceScope)
    Assert ($CustomResourceScope -eq "configured-demo-FiveMailboxes") "Read scope name from the selected environment"
}
function global:Test-ServicePrincipalAuthorization {
    param($Identity, $Resource)
    $global:setupMock.tested.Add([string]$Resource)
    return [pscustomobject]@{ Resource = $Resource; InScope = $Resource -ne "excluded@example.org" }
}
try {
    Reset-State
    Expect-Failure @{ Stage = "Provision" } "ConfirmDemoTenant"
    Assert ($global:setupMock.calls.Count -eq 0) "Unconfirmed tenant must not provision"
    & $scriptPath -Stage Provision -Config $configPath -ConfirmDemoTenant
    Assert ($global:setupMock.calls.Count -eq 6) "Provision must save all five settings without copy-pasting"
    Assert ($global:setupMock.values.OPERATOR_IDS -eq "00000000-0000-0000-0000-000000000001") "Resolve the signed-in operator automatically"

    foreach ($stage in @("Provision", "Deploy")) {
        Reset-State
        $global:setupMock.streamProgress = $true
        & $scriptPath -Stage $stage -Config $configPath -ConfirmDemoTenant -ConfirmMailboxScope |
            ForEach-Object {
                if ($_ -eq "setup-progress:$($stage.ToLowerInvariant())") {
                    $global:setupMock.progressReceived = $true
                }
            }
        Assert $global:setupMock.progressReceived "Display live progress for $stage"
    }

    Reset-State
    $global:setupMock.provisionFails = $true
    Expect-Failure @{ Stage = "Provision"; ConfirmDemoTenant = $true } "provision failed"
    Assert ($global:setupMock.calls.Count -eq 1) "Failed provision must not report success or persist settings"

    Reset-State
    Write-TestConfig -Email ""
    Expect-Failure @{ Stage = "Provision"; ConfirmDemoTenant = $true } "x-setup.acmeEmail"
    Assert ($global:setupMock.calls.Count -eq 0) "Invalid configuration must fail before Azure operations"
    Write-TestConfig -Excluded "USER1@EXAMPLE.ORG"
    Expect-Failure @{ Stage = "Exchange" } "existing sixth mailbox"
    Write-TestConfig -Excluded ""
    Expect-Failure @{ Stage = "Exchange" } "existing sixth mailbox"

    Reset-State
    Expect-Failure @{ Stage = "Deploy" } "ConfirmMailboxScope"
    Assert (@($global:setupMock.calls | Where-Object { $_[0] -eq "deploy" -or $_[1] -eq "set" }).Count -eq 0) "Unconfirmed scope must not enable delivery"
    & $scriptPath -Stage Deploy -Config $configPath -ConfirmMailboxScope
    Assert ($global:setupMock.calls[-2][0] -eq "deploy") "Confirmed setup must run azd deploy"

    Reset-State
    $global:setupMock.valueFails = $true
    Expect-Failure @{ Stage = "Deploy"; ConfirmMailboxScope = $true } "get-value AZURE_SUBSCRIPTION_ID failed"
    Assert ($global:setupMock.calls.Count -eq 1) "Failed environment lookup must stop deployment"

    Reset-State
    & $scriptPath -Stage Entra -Config $configPath
    Assert ($global:setupMock.assigned.Count -eq 6) "Assign the configured operator and five demo users"
    Assert ($global:setupMock.assigned[0] -eq $global:setupMock.values.OPERATOR_IDS) "Use the saved operator, not a different signed-in administrator"

    Reset-State
    & $scriptPath -Stage Exchange -Config $configPath | Out-Null
    Assert ($global:setupMock.tested.Count -eq 6 -and
        $global:setupMock.tested[-1] -eq "excluded@example.org") "Read and test the excluded mailbox from configuration"
    Assert ($global:setupMock.exchangePrincipal.AppId -eq $global:setupMock.values.AZURE_IDENTITY_CLIENT_ID -and
        $global:setupMock.exchangePrincipal.ObjectId -eq $global:setupMock.values.AZURE_IDENTITY_PRINCIPAL_ID) "Use runtime identity IDs, not the web app ID"

    Reset-State
    Remove-Item -LiteralPath $configPath
    $global:setupMock.onConfirm = {
        $templateCopy = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        Assert ($templateCopy.'x-demo'.users[0].userPrincipalName -like '*@contoso.onmicrosoft.com') "Create a demo-only template before pausing"
        Write-TestConfig
    }
    $global:setupMock.prompts.Enqueue("")
    & $scriptPath -Stage Configure -Config $configPath
    Assert ($global:setupMock.prompts.Count -eq 0 -and $global:setupMock.calls.Count -eq 0) "Confirm the edited file without Azure operations"
    $private = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert ($private.'x-demo'.users[0].userPrincipalName -eq "user1@example.org") "Read demo users from the edited file"
    $global:setupMock.onConfirm = $null
    $global:setupMock.prompts.Enqueue("")
    $before = Get-Content -LiteralPath $configPath -Raw
    & $scriptPath -Stage Configure -Config $configPath
    Assert ($global:setupMock.prompts.Count -eq 0) "Confirm existing files without individual setting prompts"
    Assert ((Get-Content -LiteralPath $configPath -Raw) -ceq $before) "Do not overwrite an existing uploaded configuration"
    if (-not $IsWindows) {
        Assert ([IO.File]::GetUnixFileMode($configPath) -eq
            ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)) "Private file must be owner-only"
    } else {
        $permissions = Get-Acl -LiteralPath $configPath
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Assert $permissions.AreAccessRulesProtected "Private file must not inherit broad Windows permissions"
        Assert (@($permissions.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ne $user
        }).Count -eq 0) "Private file must grant access only to the current Windows user"
    }
    Reset-State
    Write-TestConfig -Email ""
    $global:setupMock.onConfirm = { Write-TestConfig }
    $global:setupMock.prompts.Enqueue("")
    & $scriptPath -Stage Configure -Config $configPath
    Assert ($global:setupMock.prompts.Count -eq 0) "Allow an existing invalid file to be corrected before validation"

    Reset-State
    Remove-Item -LiteralPath $configPath
    $global:setupMock.prompts.Enqueue("")
    Expect-Failure @{ Stage = "Configure" } "do not deploy template users"
    Assert ($global:setupMock.calls.Count -eq 0) "Unedited template must fail validation before Azure operations"

    Reset-State
    Remove-Item -LiteralPath $configPath
    $global:setupMock.onConfirm = {
        Remove-Item -LiteralPath $configPath
        Write-TestConfig
    }
    $global:setupMock.prompts.Enqueue("")
    & $scriptPath -Stage Provision -Config $configPath -ConfirmDemoTenant
    Assert ($global:setupMock.prompts.Count -eq 0 -and $global:setupMock.calls.Count -eq 6) "Provision must pause for a missing config and use the uploaded replacement"

    Reset-State
    $templatePath = Join-Path (Join-Path $PSScriptRoot "..") "config/config.json"
    $templateBefore = Get-Content -LiteralPath $templatePath -Raw
    $failure = $null
    try { & $scriptPath -Stage Configure -Config $templatePath } catch { $failure = $_.Exception.Message }
    Assert ($failure -like "*tracked template*") "Reject the tracked template as the editable private file"
    Assert ((Get-Content -LiteralPath $templatePath -Raw) -ceq $templateBefore) "Keep the published demo template unchanged"

    Reset-State
    foreach ($answer in @("", "YES", "YES")) { $global:setupMock.prompts.Enqueue($answer) }
    & $scriptPath -Config $configPath
    Assert (($global:setupMock.stages -join ",") -eq "Configure,Provision,Entra,Exchange,Deploy") "Default setup must run all stages in order"

    Reset-State
    foreach ($answer in @("", "no")) { $global:setupMock.prompts.Enqueue($answer) }
    Expect-Failure @{} "cancelled before provisioning"
    Assert (($global:setupMock.stages -join ",") -eq "Configure") "Declining tenant confirmation must stop before provisioning"

    Reset-State
    foreach ($answer in @("", "YES", "")) { $global:setupMock.prompts.Enqueue($answer) }
    Expect-Failure @{} "Delivery remains disabled"
    Assert (($global:setupMock.stages -join ",") -eq "Configure,Provision,Entra,Exchange") "Declining mailbox confirmation must not deploy"

    foreach ($failedStage in @("Configure", "Provision", "Entra", "Exchange", "Deploy")) {
        Reset-State
        $global:setupMock.failedStage = $failedStage
        foreach ($answer in @("", "YES", "YES")) { $global:setupMock.prompts.Enqueue($answer) }
        Expect-Failure @{} "Setup stopped at $failedStage"
        Assert ($global:setupMock.stages[-1] -eq $failedStage) "Never run another stage after a failure"
    }

    Write-Host "PASS: single-command setup, local-file confirmation, configuration validation, operator resolution, saved settings, confirmation gates and native failure handling."
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    if (Test-Path -LiteralPath $configPath) { Remove-Item -LiteralPath $configPath }
    Remove-Item Function:\az, Function:\azd, Function:\Read-Host, Function:\pwsh
    foreach ($name in @("Get-Module", "Connect-MgGraph", "Get-MgServicePrincipal",
        "Get-MgServicePrincipalAppRoleAssignedTo", "New-MgServicePrincipalAppRoleAssignedTo",
        "Get-MgOauth2PermissionGrant", "New-MgOauth2PermissionGrant", "Connect-ExchangeOnline",
        "Get-EXOMailbox", "Get-ServicePrincipal", "New-ServicePrincipal", "Get-ManagementScope",
        "New-ManagementScope", "Get-ManagementRoleAssignment", "New-ManagementRoleAssignment",
        "Test-ServicePrincipalAuthorization")) {
        Remove-Item "Function:\$name"
    }
    Remove-Variable setupMock -Scope Global -ErrorAction SilentlyContinue
}
