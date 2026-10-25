param(
    [Parameter(Mandatory)][guid]$PrincipalObjectId,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$IdentityResourceId = $env:AZURE_IDENTITY_RESOURCE_ID
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "aci-deployment.ps1")
. (Join-Path $PSScriptRoot "entra-graph.ps1")
if (-not $TenantId -or -not $IdentityResourceId) {
    throw "Run this helper through azd provision, or supply -TenantId and -IdentityResourceId for the provisioned ACI identity."
}
Assert-AciManagedIdentity -TenantId $TenantId -PrincipalObjectId $PrincipalObjectId -IdentityResourceId $IdentityResourceId
$query = [uri]::EscapeDataString("appId eq '00000003-0000-0000-c000-000000000000'")
$principals = @((Invoke-Graph -Method GET -Path "servicePrincipals?`$filter=$query&`$select=id,appRoles").value)
if ($principals.Count -ne 1) { throw "Microsoft Graph service principal could not be resolved uniquely." }
$graph = $principals[0]
$role = @($graph.appRoles | Where-Object {
    $_.value -eq "User.Read.All" -and $_.isEnabled -and "Application" -in $_.allowedMemberTypes
})
if ($role.Count -ne 1) { throw "Graph application User.Read.All role definition not found uniquely." }
$mailRoles = @($graph.appRoles | Where-Object value -eq "Mail.Send")
$existing = [System.Collections.Generic.List[object]]::new()
$path = "servicePrincipals/$PrincipalObjectId/appRoleAssignments"
do {
    $page = Invoke-Graph -Method GET -Path $path
    foreach ($assignment in $page.value) { $existing.Add($assignment) }
    $path = $null
    $next = $page.PSObject.Properties["@odata.nextLink"]
    if ($next -and $next.Value) {
        $prefix = "https://graph.microsoft.com/v1.0/"
        if (-not ([string]$next.Value).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected Graph pagination URL while checking runtime permissions."
        }
        $path = $next.Value.Substring($prefix.Length)
    }
} while ($path)
if ($existing | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -in $mailRoles.id }) {
    throw "Unscoped Entra Mail.Send detected. Remove it before using default Exchange Application RBAC."
}
if ($existing | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role[0].id }) {
    Write-Host "Runtime Graph application User.Read.All already assigned; no change."
} else {
    Invoke-Graph -Method POST -Path "servicePrincipals/$PrincipalObjectId/appRoleAssignments" -Body @{
        principalId = $PrincipalObjectId.ToString()
        resourceId = $graph.id
        appRoleId = $role[0].id
    } | Out-Null
    Write-Host "Assigned runtime Graph application User.Read.All. Allow Graph permission/token-cache propagation before readiness."
}
Write-Host "Mail, delegated consent and user/group assignments are NOT granted here."
