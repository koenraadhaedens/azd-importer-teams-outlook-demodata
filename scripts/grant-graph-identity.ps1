param(
    [Parameter(Mandatory)][guid]$PrincipalObjectId
)
$ErrorActionPreference = "Stop"
if (-not (Get-Module Microsoft.Graph.Applications -ListAvailable)) {
    throw "Install-Module Microsoft.Graph.Applications -Scope CurrentUser"
}
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$role = $graph.AppRoles | Where-Object {
    $_.Value -eq "User.Read.All" -and "Application" -in $_.AllowedMemberTypes
}
if (-not $role) { throw "Graph application User.Read.All role definition not found" }
$existing = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalObjectId -All)
if (-not ($existing | Where-Object { $_.ResourceId -eq $graph.Id -and $_.AppRoleId -eq $role.Id })) {
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalObjectId -BodyParameter @{
        PrincipalId = $PrincipalObjectId
        ResourceId = $graph.Id
        AppRoleId = $role.Id
    } | Out-Null
    Write-Host "Assigned Graph application User.Read.All explicitly."
} else {
    Write-Host "Graph User.Read.All already assigned; no change."
}
$mailRole = $graph.AppRoles | Where-Object Value -eq "Mail.Send"
if ($existing | Where-Object { $_.ResourceId -eq $graph.Id -and $_.AppRoleId -eq $mailRole.Id }) {
    throw "Unscoped Entra Mail.Send detected. Remove it before using default Exchange Application RBAC."
}
Write-Host "Mail is NOT granted here. Configure the separate five-mailbox Exchange RBAC scope."
