param(
    [string]$PublicHostname = $env:PUBLIC_HOSTNAME,
    [string]$TenantId = $env:AZURE_TENANT_ID,
    [string]$IdentityPrincipalId = $env:AZURE_IDENTITY_PRINCIPAL_ID,
    [string]$IdentityResourceId = $env:AZURE_IDENTITY_RESOURCE_ID
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Graph {
    param([string]$Method, [string]$Path, [object]$Body)
    $file = $null
    try {
        $arguments = @("rest", "--method", $Method, "--url", "https://graph.microsoft.com/v1.0/$Path",
            "--only-show-errors", "--output", "json")
        if ($null -ne $Body) {
            $file = Join-Path ([IO.Path]::GetTempPath()) ("entra-" + [guid]::NewGuid() + ".json")
            $Body | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $file
            $arguments += @("--headers", "Content-Type=application/json", "--body", "@$file")
        }
        $result = & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Graph $Method $Path failed. Authorize the deployment identity for application registration; no interactive login or consent fallback is attempted."
        }
        if ($result) { return ($result -join "`n") | ConvertFrom-Json }
    } finally {
        if ($file) { Remove-Item -LiteralPath $file -Force }
    }
}

function Save-AzdValue {
    param([string]$Name, [string]$Value)
    & azd env set $Name $Value
    if ($LASTEXITCODE -ne 0) { throw "Could not persist $Name in the current azd environment." }
}

if ($PublicHostname -notmatch '^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw "A valid discovered ACI hostname is required; run the azd endpoint initialization hook."
}
$null = [guid]::Parse($TenantId)
$null = [guid]::Parse($IdentityPrincipalId)
if ($IdentityResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[^/]+$') {
    throw "Expected the provisioned user-assigned identity resource ID."
}
$accountTenant = & az account show --query tenantId --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0 -or ([string]$accountTenant).Trim() -ne $TenantId) {
    throw "Azure CLI must already be authenticated in AZURE_TENANT_ID. Registration will not prompt for login."
}
$identity = & az identity show --ids $IdentityResourceId --output json --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "Cannot verify the provisioned user-assigned identity." }
$identity = ($identity -join "`n") | ConvertFrom-Json
if ($identity.tenantId -ne $TenantId -or $identity.principalId -ne $IdentityPrincipalId) {
    throw "Managed identity and application must belong to the configured tenant."
}

# A unique resource-derived name scopes discovery without relying on user-supplied display names.
$displayName = "azd-m365-demo-loader-$($IdentityResourceId.Split('/')[-1])-web"
$origin = "https://$PublicHostname"
$graphQuery = [uri]::EscapeDataString("appId eq '00000003-0000-0000-c000-000000000000'")
$graphPrincipals = @((
    Invoke-Graph -Method GET -Path "servicePrincipals?`$filter=$graphQuery&`$select=id,oauth2PermissionScopes"
).value)
if ($graphPrincipals.Count -ne 1) { throw "Microsoft Graph service principal could not be resolved uniquely." }
$channelScope = @($graphPrincipals[0].oauth2PermissionScopes | Where-Object {
    $_.value -eq "ChannelMessage.Send" -and $_.isEnabled
})
if ($channelScope.Count -ne 1) { throw "ChannelMessage.Send delegated scope is unavailable." }

$existingId = $env:WEB_CLIENT_ID
if ($existingId) {
    $null = [guid]::Parse($existingId)
    $filter = "appId eq '$existingId'"
} else {
    $filter = "displayName eq '$displayName'"
}
$query = [uri]::EscapeDataString($filter)
$apps = @((Invoke-Graph -Method GET -Path "applications?`$filter=$query").value)
if ($apps.Count -gt 1) { throw "Ambiguous web application; inspect registrations before retrying." }
if ($existingId -and $apps.Count -eq 0) {
    throw "Configured WEB_CLIENT_ID does not exist in this tenant; it will not be silently replaced."
}
$body = @{
    displayName = $displayName
    signInAudience = "AzureADMyOrg"
    groupMembershipClaims = "SecurityGroup"
    web = @{
        redirectUris = @("$origin/auth/callback")
        homePageUrl = "$origin/"
        logoutUrl = "$origin/auth/signed-out"
        implicitGrantSettings = @{ enableIdTokenIssuance = $false; enableAccessTokenIssuance = $false }
    }
    requiredResourceAccess = @(@{
        resourceAppId = "00000003-0000-0000-c000-000000000000"
        resourceAccess = @(@{ id = $channelScope[0].id; type = "Scope" })
    })
}
if ($apps.Count -eq 0) {
    $app = Invoke-Graph -Method POST -Path "applications" -Body $body
} else {
    $app = $apps[0]
    # Explicit WEB_CLIENT_ID supports migrating the existing dedicated registration.
    # Refuse to widen a multitenant registration or preserve unrelated requested permissions.
    if ($app.signInAudience -ne "AzureADMyOrg") { throw "Only a dedicated single-tenant application is supported." }
    foreach ($resource in $app.requiredResourceAccess) {
        if ($resource.resourceAppId -ne $body.requiredResourceAccess[0].resourceAppId) {
            throw "Existing app requests unrelated APIs; use a dedicated registration."
        }
        foreach ($permission in $resource.resourceAccess) {
            if ($permission.id -ne $channelScope[0].id -or $permission.type -ne "Scope") {
                throw "Existing app requests unrelated permissions; review manually before migration."
            }
        }
    }
    Invoke-Graph -Method PATCH -Path "applications/$($app.id)" -Body $body | Out-Null
}
# Save immediately so a later failure can resume the same registration.
Save-AzdValue WEB_CLIENT_ID $app.appId
Save-AzdValue WEB_APPLICATION_OBJECT_ID $app.id

$ficName = "aci-managed-identity"
$trust = @{
    name = $ficName
    issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    subject = $IdentityPrincipalId
    audiences = @("api://AzureADTokenExchange")
    description = "Trust the azd-provisioned ACI user-assigned managed identity."
}
$credentials = @((Invoke-Graph -Method GET -Path "applications/$($app.id)/federatedIdentityCredentials").value)
$fic = @($credentials | Where-Object name -eq $ficName)
if ($fic.Count -gt 1) { throw "Duplicate managed-identity federation entries; review manually." }
if ($fic.Count -eq 0) {
    Invoke-Graph -Method POST -Path "applications/$($app.id)/federatedIdentityCredentials" -Body $trust | Out-Null
} elseif ($fic[0].issuer -ne $trust.issuer -or $fic[0].subject -ne $trust.subject -or
    @($fic[0].audiences).Count -ne 1 -or $fic[0].audiences[0] -ne $trust.audiences[0]) {
    Invoke-Graph -Method PATCH -Path "applications/$($app.id)/federatedIdentityCredentials/$($fic[0].id)" -Body $trust | Out-Null
}
$spQuery = [uri]::EscapeDataString("appId eq '$($app.appId)'")
$principals = @((Invoke-Graph -Method GET -Path "servicePrincipals?`$filter=$spQuery").value)
if ($principals.Count -gt 1) { throw "Ambiguous enterprise application." }
if ($principals.Count -eq 0) {
    $sp = Invoke-Graph -Method POST -Path "servicePrincipals" -Body @{
        appId = $app.appId
        appRoleAssignmentRequired = $true
    }
} else {
    $sp = $principals[0]
    Invoke-Graph -Method PATCH -Path "servicePrincipals/$($sp.id)" -Body @{
        appRoleAssignmentRequired = $true
    } | Out-Null
}
Save-AzdValue WEB_SERVICE_PRINCIPAL_ID $sp.id
Save-AzdValue WEB_REGISTERED_HOSTNAME $PublicHostname
Write-Host "Web registration and managed-identity trust configured for $origin."
Write-Host "No secret/certificate was created and no administrator consent or user/group assignment was granted."
Write-Host "An administrator must grant ChannelMessage.Send consent and enterprise-app assignments before users sign in."
