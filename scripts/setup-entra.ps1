param(
    [Parameter(Mandatory)][guid]$WebClientId,
    [Parameter(Mandatory)][string[]]$AllowedObjectIds,
    [switch]$GrantConsent
)
$ErrorActionPreference = "Stop"
if (-not (Get-Module Microsoft.Graph.Applications -ListAvailable)) {
    throw "Install-Module Microsoft.Graph.Applications -Scope CurrentUser"
}
if ($GrantConsent -and -not (Get-Module Microsoft.Graph.Identity.SignIns -ListAvailable)) {
    throw "Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"
}
foreach ($id in $AllowedObjectIds) { $null = [guid]::Parse($id) }
$scopes = @("Application.Read.All", "AppRoleAssignment.ReadWrite.All")
if ($GrantConsent) { $scopes += "DelegatedPermissionGrant.ReadWrite.All" }
# This administrator-only helper is deliberately not called by an azd hook.
Connect-MgGraph -Scopes $scopes -NoWelcome
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$principals = @(Get-MgServicePrincipal -Filter "appId eq '$WebClientId'")
if ($principals.Count -ne 1) { throw "Run azd provision to create the dedicated enterprise application first." }
$sp = $principals[0]
if (-not $sp.AppRoleAssignmentRequired) { throw "Enterprise application must require assignment." }
$assigned = @(Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All)
foreach ($id in $AllowedObjectIds) {
    if ($id -notin $assigned.PrincipalId) {
        New-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -BodyParameter @{
            PrincipalId = $id
            ResourceId = $sp.Id
            AppRoleId = [guid]::Empty
        } | Out-Null
    }
}
if ($GrantConsent) {
    $grants = @(Get-MgOauth2PermissionGrant -Filter "clientId eq '$($sp.Id)' and consentType eq 'AllPrincipals'")
    $grant = $grants | Where-Object ResourceId -eq $graph.Id
    if (-not $grant) {
        New-MgOauth2PermissionGrant -BodyParameter @{
            ClientId = $sp.Id; ResourceId = $graph.Id
            ConsentType = "AllPrincipals"; Scope = "ChannelMessage.Send offline_access"
        } | Out-Null
    } elseif ("ChannelMessage.Send" -notin ($grant.Scope -split " ") -or
        "offline_access" -notin ($grant.Scope -split " ")) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope (
            (($grant.Scope -split " ") + @("ChannelMessage.Send", "offline_access") |
                Sort-Object -Unique) -join " "
        )
    }
}
Write-Host "Administrator-reviewed assignments/consent applied. No application credential was created."
