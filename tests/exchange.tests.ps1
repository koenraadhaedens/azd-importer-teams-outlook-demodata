$ErrorActionPreference = "Stop"
$scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "scripts/setup-exchange.ps1"
$global:exchangeMock = @{}

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Reset-State {
    $global:exchangeMock = @{
        principals = [System.Collections.Generic.List[object]]::new()
        scopes = [System.Collections.Generic.List[object]]::new()
        assignments = [System.Collections.Generic.List[object]]::new()
        tested = [System.Collections.Generic.List[string]]::new()
        mailboxes = @{}
        failScope = $false
        emptyScope = $false
    }
    foreach ($index in 1..6) {
        $global:exchangeMock.mailboxes["user$index@example.org"] = "user$index@example.org"
    }
}
function New-TestScope {
    param([string]$Name)
    $filter = ((5..1) | ForEach-Object {
        "(PrimarySmtpAddress -eq 'USER$_@example.org')"
    }) -join " -or "
    return [pscustomobject]@{
        Name = $Name; RecipientFilter = "($filter)"; Exclusive = $false
        RecipientRoot = $null; ServerFilter = $null
    }
}
function Expect-Failure {
    param([hashtable]$Parameters, [string]$Message)
    $failure = $null
    try { & $scriptPath @Parameters | Out-Null } catch { $failure = $_.Exception.Message }
    Assert ($failure -and $failure.Contains($Message)) "Expected failure containing: $Message; received: $failure"
}
function global:Get-Module {
    param($Name, [switch]$ListAvailable)
    if ($Name -eq "ExchangeOnlineManagement") { return @{ Name = $Name } }
    throw "Unexpected module lookup"
}
function global:Connect-ExchangeOnline { param([bool]$ShowBanner) }
function global:Get-EXOMailbox {
    param($Identity)
    if ($global:exchangeMock.mailboxes.ContainsKey([string]$Identity)) {
        return [pscustomobject]@{ PrimarySmtpAddress = $global:exchangeMock.mailboxes[[string]$Identity] }
    }
    throw "Unknown test mailbox"
}
function global:Get-ServicePrincipal { $global:exchangeMock.principals.ToArray() }
function global:New-ServicePrincipal {
    param($AppId, $ObjectId, $DisplayName)
    $global:exchangeMock.principals.Add([pscustomobject]@{ AppId = $AppId; ObjectId = $ObjectId })
}
function global:Get-ManagementScope { $global:exchangeMock.scopes.ToArray() }
function global:New-ManagementScope {
    [CmdletBinding()]
    param($Name, $RecipientRestrictionFilter)
    if ($global:exchangeMock.failScope) { throw "Scope creation failed" }
    if ($global:exchangeMock.emptyScope) { return }
    $scope = New-TestScope $Name
    $scope.RecipientFilter = $RecipientRestrictionFilter
    $global:exchangeMock.scopes.Add($scope)
    return $scope
}
function global:Get-ManagementRoleAssignment {
    [CmdletBinding()]
    param($Identity, $RoleAssignee)
    if ($Identity) {
        $global:exchangeMock.assignments | Where-Object Name -eq $Identity
    } else {
        $global:exchangeMock.assignments | Where-Object AssigneeId -eq $RoleAssignee
    }
}
function global:New-ManagementRoleAssignment {
    [CmdletBinding()]
    param($Name, $App, $Role, $CustomResourceScope)
    Assert (@($global:exchangeMock.scopes | Where-Object Name -eq $CustomResourceScope).Count -eq 1) "Assignment must use an existing resolved scope"
    $global:exchangeMock.assignments.Add([pscustomobject]@{
        Name = $Name; AssigneeId = $App; Role = $Role; CustomResourceScope = $CustomResourceScope
    })
}
function global:Test-ServicePrincipalAuthorization {
    param($Identity, $Resource)
    $global:exchangeMock.tested.Add([string]$Resource)
    return [pscustomobject]@{ Resource = $Resource; InScope = $Resource -ne "user6@example.org" }
}

try {
    $parameters = @{
        ApplicationId = [guid]::NewGuid()
        PrincipalObjectId = [guid]::NewGuid()
        DemoUpns = @((1..5) | ForEach-Object { "user$_@example.org" })
        OutOfScopeTestUpn = "user6@example.org"
        ScopeName = "new-FiveMailboxes"
    }
    Reset-State
    & $scriptPath @parameters | Out-Null
    $state = $global:exchangeMock
    Assert ($state.scopes.Count -eq 1 -and $state.assignments.Count -eq 1) "Fresh setup must create scope and assignment"
    Assert ($state.tested.Count -eq 6) "Always test all five demo mailboxes and the excluded mailbox"
    & $scriptPath @parameters | Out-Null
    Assert ($state.scopes.Count -eq 1 -and $state.assignments.Count -eq 1) "Repeated setup must be idempotent"

    $oldPrincipal = $parameters.PrincipalObjectId
    $parameters.ApplicationId = [guid]::NewGuid()
    $parameters.PrincipalObjectId = [guid]::NewGuid()
    $parameters.ScopeName = "demoload8-FiveMailboxes"
    & $scriptPath @parameters | Out-Null
    Assert ($state.scopes.Count -eq 1 -and $state.assignments.Count -eq 2) "New deployment must reuse the scope with its own assignment"
    Assert ($state.assignments[0].AssigneeId -eq $oldPrincipal) "Do not change the old principal's assignment"
    Assert ($state.assignments[1].CustomResourceScope -eq "new-FiveMailboxes") "Do not use the nonexistent requested scope name"

    Reset-State
    $state = $global:exchangeMock
    $state.scopes.Add((New-TestScope "old-FiveMailboxes"))
    & $scriptPath @parameters | Out-Null
    Assert ($state.scopes.Count -eq 1 -and $state.assignments[0].CustomResourceScope -eq "old-FiveMailboxes") "Canonical parentheses, case and order must not prevent reuse"
    $state.assignments[0].AssigneeId = [guid]::NewGuid()
    Expect-Failure $parameters "conflicts with the runtime principal"
    Assert ($state.assignments.Count -eq 1) "Conflicting assignment must not be overwritten"

    Reset-State
    $state = $global:exchangeMock
    $scope = New-TestScope $parameters.ScopeName
    $scope.RecipientFilter += " -or PrimarySmtpAddress -eq 'user6@example.org'"
    $state.scopes.Add($scope)
    Expect-Failure $parameters "existing scopes will not be changed"
    Assert ($state.assignments.Count -eq 0) "Never grant a mismatched named scope"

    Reset-State
    $state = $global:exchangeMock
    foreach ($name in @("old-a", "old-b")) { $state.scopes.Add((New-TestScope $name)) }
    Expect-Failure $parameters "Multiple equivalent mailbox scopes"
    Assert ($state.assignments.Count -eq 0) "Ambiguous scope discovery must fail before assignment"

    foreach ($kind in @("Exclusive", "RecipientRoot", "ServerFilter", "dynamic")) {
        Reset-State
        $state = $global:exchangeMock
        $scope = New-TestScope "not-reusable"
        if ($kind -eq "dynamic") {
            $scope.RecipientFilter += " -and RecipientTypeDetails -eq 'UserMailbox'"
        } elseif ($kind -eq "Exclusive") {
            $scope.Exclusive = $true
        } else {
            $scope.$kind = "restricted"
        }
        $state.scopes.Add($scope)
        & $scriptPath @parameters | Out-Null
        Assert ($state.scopes.Count -eq 2 -and $state.assignments[0].CustomResourceScope -eq $parameters.ScopeName) "Do not reuse $kind scope"
    }

    foreach ($mode in @("failScope", "emptyScope")) {
        Reset-State
        $state = $global:exchangeMock
        $state[$mode] = $true
        $message = if ($mode -eq "failScope") { "Scope creation failed" } else { "No management scope was resolved" }
        Expect-Failure $parameters $message
        Assert ($state.assignments.Count -eq 0) "Never assign a missing scope"
    }

    Reset-State
    $global:exchangeMock.principals.Add([pscustomobject]@{
        AppId = $parameters.ApplicationId; ObjectId = [guid]::NewGuid()
    })
    Expect-Failure $parameters "service principal conflicts"

    Reset-State
    $global:exchangeMock.mailboxes["user6@example.org"] = "user1@example.org"
    Expect-Failure $parameters "test UPN resolves to a demo mailbox"
    Write-Host "PASS: Exchange scope reuse, fresh installs, idempotency, new identities, exact filters, conflicts and missing scopes."
} finally {
    foreach ($name in @("Get-Module", "Connect-ExchangeOnline", "Get-EXOMailbox",
        "Get-ServicePrincipal", "New-ServicePrincipal", "Get-ManagementScope",
        "New-ManagementScope", "Get-ManagementRoleAssignment",
        "New-ManagementRoleAssignment", "Test-ServicePrincipalAuthorization")) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable exchangeMock -Scope Global -ErrorAction SilentlyContinue
}
