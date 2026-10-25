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
    containerExists = $false
    fqdn = "azure-assigned-hash.westeurope.azurecontainer.io"
    deployments = [System.Collections.Generic.List[object]]::new()
    healthUrls = [System.Collections.Generic.List[string]]::new()
    healthReady = $true
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function global:azd {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq "env" -and $args[1] -eq "get-value") {
        if ($global:registrationMock.saved.ContainsKey($args[2])) {
            return $global:registrationMock.saved[$args[2]]
        }
        $global:LASTEXITCODE = 1
        return
    }
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
    if ($args[0] -eq "container" -and $args[1] -eq "list") {
        return ConvertTo-Json -Depth 5 -Compress -InputObject @(if ($state.containerExists) {
            @{ name = $env:ACI_NAME; ipAddress = @{ fqdn = $state.fqdn } }
        })
    }
    if ($args[0] -eq "container" -and $args[1] -eq "show") { return $state.fqdn }
    if ($args[0] -eq "deployment") {
        $file = $args[[array]::IndexOf($args, "--parameters") + 1].Substring(1)
        $state.deployments.Add((Get-Content -Raw $file | ConvertFrom-Json).parameters)
        $state.containerExists = $true
        return
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
function global:Invoke-WebRequest {
    param([string]$Uri, [int]$TimeoutSec)
    $global:registrationMock.healthUrls.Add($Uri)
    return @{
        StatusCode = 200
        Content = $(if ($global:registrationMock.healthReady) { '{"status":"ready"}' } else { '{"status":"initializing"}' })
    }
}
function global:Start-Sleep { param([int]$Seconds) }
$oldId = $env:WEB_CLIENT_ID
$environment = @{}
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
    $state.denyGraph = $false
    $values = @{
        AZURE_RESOURCE_GROUP = "rg-test"
        AZURE_IDENTITY_RESOURCE_ID = $state.identityId
        AZURE_IDENTITY_PRINCIPAL_ID = $state.principal
        AZURE_IDENTITY_CLIENT_ID = [guid]::NewGuid().ToString()
        AZURE_TENANT_ID = $state.tenant
        JOURNAL_BLOB_URL = "https://example.blob.core.windows.net/journal/runs.json"
        ACI_NAME = "aci-test"
        ACI_DNS_LABEL = "label-not-the-returned-host"
        AZURE_LOG_WORKSPACE_NAME = "logs-test"
        AZURE_CERT_STORAGE_NAME = "certtest"
        ACME_EMAIL = "operator@example.org"
        OPERATOR_IDS = '["' + [guid]::NewGuid().ToString() + '"]'
        DEMO_TENANT_CONFIRMED = "true"
        DELIVERY_ENABLED = "true"
        MAILBOX_SCOPE_CONFIRMED = "true"
        PUBLIC_HOSTNAME = "stale.example.org"
        PUBLIC_URL = ""
    }
    foreach ($name in $values.Keys) {
        $environment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $values[$name])
    }
    $initialize = Join-Path (Join-Path $PSScriptRoot "..") "scripts/initialize-web-endpoint.ps1"
    $deploy = Join-Path (Join-Path $PSScriptRoot "..") "scripts/deploy.ps1"
    & $initialize
    Assert ($state.deployments.Count -eq 1) "First initialization should create exactly one bootstrap"
    $bootstrap = $state.deployments[0]
    Assert $bootstrap.bootstrap.value "First deployment must use initialization mode"
    Assert (-not $bootstrap.deliveryEnabled.value) "Bootstrap must disable real delivery"
    Assert ($bootstrap.webClientId.value -eq "" -and $bootstrap.publicHostname.value -eq "") "Bootstrap must not use guessed IDs/hostname"
    Assert ($state.saved.PUBLIC_HOSTNAME -eq $state.fqdn) "Use the actual Azure FQDN, not the label or previous custom hostname"
    Assert ($state.saved.PUBLIC_URL -eq "https://$($state.fqdn)") "Discovered URL was not saved"
    Assert ($state.saved.WEB_REGISTERED_HOSTNAME -eq $state.fqdn) "Registration success must bind to the discovered hostname"
    $patch = @($state.requests | Where-Object {
        $_.method -eq "PATCH" -and $_.path -eq "applications/$($state.app.id)"
    })[-1]
    Assert ($patch.body.web.redirectUris[0] -eq "https://$($state.fqdn)/auth/callback") "Entra must use the discovered FQDN"
    & $initialize
    Assert ($state.deployments.Count -eq 1) "Rerun must not reset an existing group to bootstrap"
    & $deploy
    Assert ($state.deployments.Count -eq 2) "Final deployment was not applied"
    Assert (-not $state.deployments[1].bootstrap.value) "Final deployment must start the real app"
    Assert ($state.deployments[1].publicHostname.value -eq $state.fqdn) "Caddy/app hostname differs from Entra"
    Assert ($state.healthUrls[0] -eq "https://$($state.fqdn)/healthz") "Health must check discovered HTTPS endpoint"
    $state.fqdn = "changed.westeurope.azurecontainer.io"
    $failed = $false
    try { & $deploy } catch { $failed = $true }
    Assert $failed "Hostname drift must stop deployment until registration is reconciled"
    Assert ($state.deployments.Count -eq 2) "Drift must be rejected before updating the group"
    $state.saved.PUBLIC_HOSTNAME = $state.fqdn
    $failed = $false
    try { & $deploy } catch { $failed = $true }
    Assert $failed "A saved hostname without successful Entra reconciliation must be rejected"
    Assert ($state.deployments.Count -eq 2) "Incomplete registration must not start the real app"
    & $initialize
    $state.healthReady = $false
    $failed = $false
    try { & $deploy } catch { $failed = $true }
    Assert $failed "HTTP 200 without ready status must not be accepted as successful deployment"
    Write-Host "PASS: registration/trust, safe bootstrap, actual FQDN, reruns, final deployment, drift/partial-registration rejection and strict HTTPS readiness."
} finally {
    $env:WEB_CLIENT_ID = $oldId
    foreach ($name in $environment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    Remove-Item Function:\az, Function:\azd, Function:\Invoke-WebRequest, Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable registrationMock -Scope Global
}
