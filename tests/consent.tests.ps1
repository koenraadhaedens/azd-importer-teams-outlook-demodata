$ErrorActionPreference = "Stop"
$scriptPath = Join-Path (Join-Path $PSScriptRoot "..") "scripts/setup-entra.ps1"
$global:consentMock = @{
    graph = [guid]::NewGuid().ToString()
    app = [guid]::NewGuid().ToString()
    grant = $null
    writes = 0
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function global:Get-Module { param($Name, [switch]$ListAvailable) return @{ Name = $Name } }
function global:Connect-MgGraph { param($Scopes, [switch]$NoWelcome) }
function global:Get-MgServicePrincipal {
    param($Filter)
    if ($Filter.Contains("00000003-0000-0000-c000-000000000000")) {
        return @{ Id = $global:consentMock.graph }
    }
    return @{ Id = $global:consentMock.app; AppRoleAssignmentRequired = $true }
}
function global:Get-MgServicePrincipalAppRoleAssignedTo {
    param($ServicePrincipalId, [switch]$All)
    return @()
}
function global:New-MgServicePrincipalAppRoleAssignedTo {
    param($ServicePrincipalId, $BodyParameter)
}
function global:Get-MgOauth2PermissionGrant {
    param($Filter)
    if ($global:consentMock.grant) { return $global:consentMock.grant }
}
function global:New-MgOauth2PermissionGrant {
    param($BodyParameter)
    $global:consentMock.writes++
    $global:consentMock.grant = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString()
        ResourceId = $BodyParameter.ResourceId
        Scope = $BodyParameter.Scope
    }
}
function global:Update-MgOauth2PermissionGrant {
    param($OAuth2PermissionGrantId, $Scope)
    $global:consentMock.writes++
    $global:consentMock.grant.Scope = $Scope
}
try {
    $parameters = @{
        WebClientId = [guid]::NewGuid()
        AllowedObjectIds = @([guid]::NewGuid().ToString())
        GrantConsent = $true
    }
    & $scriptPath @parameters
    Assert ($global:consentMock.grant.Scope -eq "ChannelMessage.Send offline_access") "New grants must include refresh capability"
    & $scriptPath @parameters
    Assert ($global:consentMock.writes -eq 1) "Repeated consent must be idempotent"
    $global:consentMock.grant.Scope = "ChannelMessage.Send"
    & $scriptPath @parameters
    Assert ($global:consentMock.writes -eq 2) "Upgrade existing consent to support background renewal"
    Assert ("offline_access" -in ($global:consentMock.grant.Scope -split " ")) "Retain offline_access"
    Assert ("ChannelMessage.Send" -in ($global:consentMock.grant.Scope -split " ")) "Retain channel sending"
    $parameters.GrantConsent = $false
    & $scriptPath @parameters
    Assert ($global:consentMock.writes -eq 2) "Never update consent without the administrator switch"
    Write-Host "PASS: delegated background renewal consent, upgrade, idempotency and explicit administrator opt-in."
} finally {
    foreach ($name in @("Get-Module", "Connect-MgGraph", "Get-MgServicePrincipal",
        "Get-MgServicePrincipalAppRoleAssignedTo", "New-MgServicePrincipalAppRoleAssignedTo",
        "Get-MgOauth2PermissionGrant", "New-MgOauth2PermissionGrant",
        "Update-MgOauth2PermissionGrant")) {
        Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Variable consentMock -Scope Global -ErrorAction SilentlyContinue
}
