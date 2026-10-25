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
foreach ($upn in $DemoUpns + $OutOfScopeTestUpn) {
    if ($upn -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$') { throw "Invalid mailbox UPN format" }
    $mailbox = Get-EXOMailbox -Identity $upn
    if (-not $mailbox) { throw "Mailbox missing: $upn" }
}
$sp = Get-ServicePrincipal | Where-Object AppId -eq $ApplicationId
if (-not $sp) {
    New-ServicePrincipal -AppId $ApplicationId -ObjectId $PrincipalObjectId -DisplayName "M365 demo loader" | Out-Null
}
# Scope exact primary SMTP addresses resolved from the five UPNs, not a broad domain.
$addresses = @($DemoUpns | ForEach-Object { (Get-EXOMailbox -Identity $_).PrimarySmtpAddress.ToString() })
$filter = ($addresses | ForEach-Object { "PrimarySmtpAddress -eq '$($_.Replace("'", "''"))'" }) -join " -or "
$scope = Get-ManagementScope -Identity $ScopeName -ErrorAction SilentlyContinue
if (-not $scope) {
    New-ManagementScope -Name $ScopeName -RecipientRestrictionFilter $filter | Out-Null
} elseif ($scope.RecipientFilter -ne $filter) {
    Set-ManagementScope -Identity $ScopeName -RecipientRestrictionFilter $filter
}
$assignmentName = "$ScopeName-MailSend"
$assignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
if (-not $assignment) {
    New-ManagementRoleAssignment -Name $assignmentName -App $PrincipalObjectId `
        -Role "Application Mail.Send" -CustomResourceScope $ScopeName | Out-Null
} elseif ($assignment.Role -ne "Application Mail.Send" -or $assignment.CustomResourceScope -ne $ScopeName) {
    throw "Existing role assignment conflicts with requested scope; inspect manually."
}
foreach ($upn in $DemoUpns) {
    Test-ServicePrincipalAuthorization -Identity $PrincipalObjectId -Resource $upn | Format-Table
}
Test-ServicePrincipalAuthorization -Identity $PrincipalObjectId -Resource $OutOfScopeTestUpn | Format-Table
Write-Warning "Review InScope results: five true, out-of-scope false. Grants can take time to propagate."
Write-Warning "Verify no other Exchange assignments or Entra Mail.Send grant broaden access."
Write-Host "Only after verification set MAILBOX_SCOPE_CONFIRMED=true."
