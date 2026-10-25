param(
    [Parameter(Mandatory)][uri]$PublicUrl,
    [Parameter(Mandatory)][string[]]$AllowedObjectIds,
    [string]$DisplayName = "azd-m365-demo-loader-web",
    [switch]$GrantConsent
)
$ErrorActionPreference = "Stop"
if (-not (Get-Module Microsoft.Graph.Applications -ListAvailable)) {
    throw "Install-Module Microsoft.Graph.Applications -Scope CurrentUser"
}
if ($PublicUrl.Scheme -ne "https" -and $PublicUrl.AbsoluteUri.TrimEnd("/") -ne "http://localhost:8000") {
    throw "HTTPS required except the documented localhost origin."
}
$origin = $PublicUrl.AbsoluteUri.TrimEnd("/")
foreach ($id in $AllowedObjectIds) { $null = [guid]::Parse($id) }
$scopes = @("Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All")
if ($GrantConsent -and -not (Get-Module Microsoft.Graph.Identity.SignIns -ListAvailable)) {
    throw "Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"
}
if ($GrantConsent) { $scopes += "DelegatedPermissionGrant.ReadWrite.All" }
Connect-MgGraph -Scopes $scopes -NoWelcome
$graph = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$permission = $graph.Oauth2PermissionScopes | Where-Object Value -eq "ChannelMessage.Send"
if (-not $permission) { throw "ChannelMessage.Send permission definition not found" }
$escaped = $DisplayName.Replace("'", "''")
$apps = @(Get-MgApplication -Filter "displayName eq '$escaped'")
if ($apps.Count -gt 1) { throw "Ambiguous application displayName; resolve duplicates manually." }
$body = @{
    DisplayName = $DisplayName
    SignInAudience = "AzureADMyOrg"
    GroupMembershipClaims = "SecurityGroup"
    Web = @{
        RedirectUris = @("$origin/auth/callback")
        HomePageUrl = "$origin/"
        LogoutUrl = "$origin/auth/signed-out"
        ImplicitGrantSettings = @{ EnableIdTokenIssuance = $false; EnableAccessTokenIssuance = $false }
    }
    RequiredResourceAccess = @(@{
        ResourceAppId = $graph.AppId
        ResourceAccess = @(@{ Id = $permission.Id; Type = "Scope" })
    })
}
if ($apps.Count -eq 0) {
    $app = New-MgApplication -BodyParameter $body
} else {
    $app = $apps[0]
    Update-MgApplication -ApplicationId $app.Id -BodyParameter $body
}
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
if (-not $sp) { $sp = New-MgServicePrincipal -AppId $app.AppId }
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired:$true
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
            ConsentType = "AllPrincipals"; Scope = "ChannelMessage.Send"
        } | Out-Null
    } elseif ("ChannelMessage.Send" -notin ($grant.Scope -split " ")) {
        Update-MgOauth2PermissionGrant -OAuth2PermissionGrantId $grant.Id -Scope (
            (($grant.Scope -split " ") + "ChannelMessage.Send" | Sort-Object -Unique) -join " "
        )
    }
}
Write-Host "Web application client ID: $($app.AppId)"
Write-Host "Create/rotate its credential in Entra and store ONLY in Key Vault or local ignored .env."
Write-Host "No credential was generated or printed. Explicit app authorization is still configured via OPERATOR_IDS/group."
