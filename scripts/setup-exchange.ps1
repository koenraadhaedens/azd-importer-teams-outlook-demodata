param(
    [Parameter(Mandatory)][guid]$ApplicationId,
    [Parameter(Mandatory)][guid]$PrincipalObjectId,
    [Parameter(Mandatory)][string[]]$DemoUpns,
    [Parameter(Mandatory)][string]$OutOfScopeTestUpn,
    [string]$ScopeName = "M365DemoLoaderFiveMailboxes"
)
$ErrorActionPreference = "Stop"
if (@($DemoUpns | Sort-Object -Unique).Count -ne 5) { throw "Supply exactly five distinct demo UPNs" }
if ($OutOfScopeTestUpn -in $DemoUpns) { throw "Out-of-scope test mailbox must not be a demo mailbox" }
if (-not (Get-Module ExchangeOnlineManagement -ListAvailable)) {
    throw "Install-Module ExchangeOnlineManagement -Scope CurrentUser"
}
Connect-ExchangeOnline -ShowBanner:$false
$mailboxes = @{}
foreach ($upn in $DemoUpns + $OutOfScopeTestUpn) {
    if ($upn -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$') { throw "Invalid mailbox UPN format" }
    $mailbox = Get-EXOMailbox -Identity $upn
    if (-not $mailbox) { throw "Mailbox missing: $upn" }
    $mailboxes[$upn] = $mailbox.PrimarySmtpAddress.ToString().ToLowerInvariant()
}
$addresses = @($DemoUpns | ForEach-Object { $mailboxes[$_] } | Sort-Object -Unique)
if ($addresses.Count -ne 5) { throw "Demo UPNs must resolve to five distinct mailboxes" }
if ($mailboxes[$OutOfScopeTestUpn] -in $addresses) {
    throw "Out-of-scope test UPN resolves to a demo mailbox"
}
$principals = @(Get-ServicePrincipal | Where-Object AppId -eq $ApplicationId)
if ($principals.Count -eq 0) {
    New-ServicePrincipal -AppId $ApplicationId -ObjectId $PrincipalObjectId -DisplayName "M365 demo loader" | Out-Null
} elseif ($principals.Count -ne 1 -or [string]$principals[0].ObjectId -ne [string]$PrincipalObjectId) {
    throw "Existing Exchange service principal conflicts with the runtime identity; inspect manually."
}
# Scope exact primary SMTP addresses resolved from the five UPNs, not a broad domain.
$filter = ($addresses | ForEach-Object { "PrimarySmtpAddress -eq '$($_.Replace("'", "''"))'" }) -join " -or "

function Test-ExactMailboxScope {
    param($Candidate)
    if ($Candidate.Exclusive -or $Candidate.RecipientRoot -or $Candidate.ServerFilter) {
        return $false
    }
    $pattern = "(?i)PrimarySmtpAddress\s+-eq\s+'([^']+)'"
    $clauses = [regex]::Matches([string]$Candidate.RecipientFilter, $pattern)
    $remainder = [regex]::Replace([string]$Candidate.RecipientFilter, $pattern, "")
    if ($clauses.Count -ne 5 -or $remainder -notmatch '^(?i:[\s()]|-or)*$') {
        return $false
    }
    $candidateAddresses = @($clauses | ForEach-Object {
        $_.Groups[1].Value.ToLowerInvariant()
    } | Sort-Object -Unique)
    return $candidateAddresses.Count -eq 5 -and
        -not (Compare-Object -ReferenceObject $addresses -DifferenceObject $candidateAddresses)
}

$scopes = @(Get-ManagementScope)
$namedScopes = @($scopes | Where-Object Name -eq $ScopeName)
if ($namedScopes.Count -gt 1) { throw "Ambiguous management scope name; inspect manually." }
if ($namedScopes.Count -eq 1) {
    $scope = $namedScopes[0]
    if (-not (Test-ExactMailboxScope $scope)) {
        throw "Requested scope does not select exactly the five demo addresses; existing scopes will not be changed."
    }
} else {
    $matchingScopes = @($scopes | Where-Object { Test-ExactMailboxScope $_ })
    if ($matchingScopes.Count -gt 1) {
        throw "Multiple equivalent mailbox scopes exist; rerun with an explicitly reviewed ScopeName."
    }
    if ($matchingScopes.Count -eq 1) {
        $scope = $matchingScopes[0]
    } else {
        $scope = New-ManagementScope -Name $ScopeName -RecipientRestrictionFilter $filter -ErrorAction Stop
    }
}
if (-not $scope -or -not $scope.Name) {
    throw "No management scope was resolved; no mail role assignment will be created."
}
Write-Host "Using Exchange scope '$($scope.Name)' for runtime principal $PrincipalObjectId."
$assignmentName = "DemoMailSend-$PrincipalObjectId"
$assignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
if (-not $assignment) {
    New-ManagementRoleAssignment -Name $assignmentName -App $PrincipalObjectId `
        -Role "Application Mail.Send" -CustomResourceScope $scope.Name -ErrorAction Stop | Out-Null
} else {
    $ownedAssignments = @(Get-ManagementRoleAssignment -RoleAssignee $PrincipalObjectId |
        Where-Object Name -eq $assignmentName)
    if ($assignment.Role -ne "Application Mail.Send" -or
        $assignment.CustomResourceScope -ne $scope.Name -or $ownedAssignments.Count -ne 1) {
        throw "Existing role assignment conflicts with the runtime principal, role or scope; inspect manually."
    }
}
foreach ($upn in $DemoUpns) {
    Test-ServicePrincipalAuthorization -Identity $PrincipalObjectId -Resource $upn | Format-Table
}
Test-ServicePrincipalAuthorization -Identity $PrincipalObjectId -Resource $OutOfScopeTestUpn | Format-Table
Write-Warning "Review InScope results: five true, out-of-scope false. Grants can take time to propagate."
Write-Warning "Verify no other Exchange assignments or Entra Mail.Send grant broaden access."
Write-Host "Only after verification set MAILBOX_SCOPE_CONFIRMED=true."
