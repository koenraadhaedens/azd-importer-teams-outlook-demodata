$ErrorActionPreference = "Stop"
$global:registrationMock = @{
    tenant = [guid]::NewGuid().ToString()
    principal = [guid]::NewGuid().ToString()
    identityId = "/subscriptions/$([guid]::NewGuid())/resourceGroups/demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-demo"
    scopeId = [guid]::NewGuid().ToString()
    saved = @{}
    requests = [System.Collections.Generic.List[object]]::new()
    app = $null
    fic = $null
    sp = $null
    wrongTenant = $false
    denyGraph = $false
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function global:azd {
    $global:LASTEXITCODE = 0
    Assert ($args[0] -eq "env" -and $args[1] -eq "set") "Only azd env set is expected"
    $global:registrationMock.saved[$args[2]] = $args[3]
}
function global:az {
    $global:LASTEXITCODE = 0
    $state = $global:registrationMock
    if ($args[0] -eq "account") { return $state.tenant }
    if ($args[0] -eq "identity") {
        return @{
            tenantId = $(if ($state.wrongTenant) { [guid]::NewGuid().ToString() } else { $state.tenant })
            principalId = $state.principal
        } | ConvertTo-Json -Compress
    }
    Assert ($args[0] -eq "rest") "Registration may not login, mint credentials or deploy resources"
    if ($state.denyGraph) { $global:LASTEXITCODE = 1; return }
    $method = $args[[array]::IndexOf($args, "--method") + 1]
    $url = $args[[array]::IndexOf($args, "--url") + 1]
    $path = [uri]::UnescapeDataString($url.Replace("https://graph.microsoft.com/v1.0/", ""))
    $body = $null
    if ("--body" -in $args) {
        $file = $args[[array]::IndexOf($args, "--body") + 1].Substring(1)
        $body = Get-Content -Raw $file | ConvertFrom-Json
    }
    $state.requests.Add(@{ method = $method; path = $path; body = $body })
    if ($path -match "^servicePrincipals\?.*00000003-0000-0000-c000-000000000000") {
        return @{ value = @(@{ id = [guid]::NewGuid().ToString(); oauth2PermissionScopes = @(
            @{ id = $state.scopeId; value = "ChannelMessage.Send"; isEnabled = $true }
        ) }) } | ConvertTo-Json -Depth 8 -Compress
    }
    if ($path -match "^applications\?") {
        return @{ value = @(if ($state.app) { $state.app }) } | ConvertTo-Json -Depth 12 -Compress
    }
    if ($method -eq "POST" -and $path -eq "applications") {
        $state.app = $body
        $state.app | Add-Member id ([guid]::NewGuid().ToString())
        $state.app | Add-Member appId ([guid]::NewGuid().ToString())
        return $state.app | ConvertTo-Json -Depth 12 -Compress
    }
    if ($path -match "^applications/[^/]+/federatedIdentityCredentials$") {
        if ($method -eq "GET") {
            return @{ value = @(if ($state.fic) { $state.fic }) } | ConvertTo-Json -Depth 8 -Compress
        }
        $state.fic = $body
        $state.fic | Add-Member id ([guid]::NewGuid().ToString())
        return $state.fic | ConvertTo-Json -Depth 8 -Compress
    }
    if ($method -eq "PATCH") { return }
    if ($path -match "^servicePrincipals\?") {
        return @{ value = @(if ($state.sp) { $state.sp }) } | ConvertTo-Json -Depth 8 -Compress
    }
    if ($method -eq "POST" -and $path -eq "servicePrincipals") {
        $state.sp = $body
        $state.sp | Add-Member id ([guid]::NewGuid().ToString())
        return $state.sp | ConvertTo-Json -Depth 8 -Compress
    }
    throw "Unexpected Graph operation: $method $path"
}
$oldId = $env:WEB_CLIENT_ID
$registrationScript = Join-Path (Join-Path $PSScriptRoot "..") "scripts/register-web-app.ps1"
try {
    $state = $global:registrationMock
    $env:WEB_CLIENT_ID = ""
    $parameters = @{
        PublicHostname = "loader.example.org"
        TenantId = $state.tenant
        IdentityPrincipalId = $state.principal
        IdentityResourceId = $state.identityId
    }
    & $registrationScript @parameters
    Assert ($state.saved.WEB_CLIENT_ID -eq $state.app.appId) "Client ID was not persisted"
    Assert ($state.app.web.redirectUris[0] -eq "https://loader.example.org/auth/callback") "Wrong callback"
    Assert ($state.app.web.logoutUrl -eq "https://loader.example.org/auth/signed-out") "Wrong logout"
    Assert ($state.fic.subject -eq $state.principal) "Federation subject must be principal ID"
    Assert ($state.fic.issuer -eq "https://login.microsoftonline.com/$($state.tenant)/v2.0") "Wrong issuer"
    Assert ($state.fic.audiences[0] -eq "api://AzureADTokenExchange") "Wrong audience"
    Assert ($state.sp.appRoleAssignmentRequired) "Enterprise application must require assignment"
    $posts = @($state.requests | Where-Object method -eq "POST").Count
    $env:WEB_CLIENT_ID = $state.saved.WEB_CLIENT_ID
    & $registrationScript @parameters
    Assert (@($state.requests | Where-Object method -eq "POST").Count -eq $posts) "Rerun created duplicates"
    $parameters.PublicHostname = "new.example.org"
    & $registrationScript @parameters
    $patch = @($state.requests | Where-Object {
        $_.method -eq "PATCH" -and $_.path -eq "applications/$($state.app.id)"
    })[-1]
    Assert ($patch.body.web.redirectUris[0] -eq "https://new.example.org/auth/callback") "Hostname update failed"
    $state.fic.subject = [guid]::NewGuid().ToString()
    & $registrationScript @parameters
    $trustPatch = @($state.requests | Where-Object {
        $_.method -eq "PATCH" -and $_.path -match "/federatedIdentityCredentials/"
    })[-1]
    Assert ($trustPatch.body.subject -eq $state.principal) "Changed managed-identity trust was not reconciled"
    $state.app.signInAudience = "AzureADMultipleOrgs"
    $failed = $false
    try { & $registrationScript @parameters } catch { $failed = $true }
    Assert $failed "An unrelated multitenant application must not be adopted"
    $state.app.signInAudience = "AzureADMyOrg"
    Assert (-not ($state.requests | Where-Object {
        $_.path -match "oauth2PermissionGrants|appRoleAssignedTo|addPassword"
    })) "Registration must not consent, assign or mint secrets"
    $state.wrongTenant = $true
    $failed = $false
    try { & $registrationScript @parameters } catch { $failed = $true }
    Assert $failed "Cross-tenant identity must be rejected"
    $state.wrongTenant = $false
    $state.denyGraph = $true
    $failed = $false
    try { & $registrationScript @parameters } catch { $failed = $true }
    Assert $failed "Graph authorization failure must be explicit without login fallback"
    Write-Host "PASS: noninteractive registration, idempotency, URL/trust reconciliation, tenant/application boundaries and no consent/secret side effects."
} finally {
    $env:WEB_CLIENT_ID = $oldId
    Remove-Item Function:\az, Function:\azd -ErrorAction SilentlyContinue
    Remove-Variable registrationMock -Scope Global
}
