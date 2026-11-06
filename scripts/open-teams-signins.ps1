<#
.SYNOPSIS
Opens an isolated browser sign-in for each configured demo user on Windows.
.DESCRIPTION
Run locally, not in Cloud Shell. Passwords, MFA and run authorization remain manual.
Each invocation creates fresh browser profiles; existing browser sessions are not reused.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$Url,
    [string]$Config = $env:DEMO_CONFIG_FILE,
    [string[]]$UserKeys,
    [string]$RunId,
    [ValidateSet("Edge", "Chrome")][string]$Browser = "Edge",
    [string]$BrowserPath
)
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") { throw "Run this script on a Windows desktop, not in Cloud Shell." }
if (-not $Url.IsAbsoluteUri -or $Url.Scheme -ne "https" -or
    $Url.UserInfo -or $Url.Query -or $Url.Fragment -or $Url.AbsolutePath -ne "/") {
    throw "Url must be the HTTPS app base URL, without a path, credentials, query or fragment."
}
if ($RunId -and $RunId -notmatch '^[a-zA-Z0-9_-]+$') { throw "Invalid run ID." }
if (-not $Config) {
    $Config = Join-Path (Join-Path $PSScriptRoot "..") "config\config.local.json"
}
if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    throw "Private configuration not found. Supply -Config with your deployed configuration file."
}
$configuration = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$users = @($configuration.'x-demo'.users)
if ($users.Count -eq 0 -or @($users | Where-Object {
    $_.key -notmatch '^[a-z][a-z0-9_-]{0,39}$' -or
    $_.userPrincipalName -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$'
}).Count -gt 0 -or
    @($users.key | Sort-Object -Unique).Count -ne $users.Count -or
    @($users.userPrincipalName | Sort-Object -Unique).Count -ne $users.Count) {
    throw "Configuration must contain distinct x-demo.users keys and valid UPNs."
}
if ($UserKeys) {
    foreach ($key in $UserKeys) {
        if ($key -notin $users.key) { throw "Unknown demo user key: $key" }
    }
    $users = @($users | Where-Object { $_.key -in $UserKeys })
}

if (-not $BrowserPath) {
    $relative = if ($Browser -eq "Edge") {
        "Microsoft\Edge\Application\msedge.exe"
    } else {
        "Google\Chrome\Application\chrome.exe"
    }
    foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if ($root) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $BrowserPath = $candidate
                break
            }
        }
    }
}
if (-not $BrowserPath -or -not (Test-Path -LiteralPath $BrowserPath -PathType Leaf)) {
    throw "$Browser was not found. Install it or supply -BrowserPath to its executable."
}
$BrowserPath = (Resolve-Path -LiteralPath $BrowserPath).ProviderPath
$profileRoot = Join-Path $env:LOCALAPPDATA ("DemoLoader\BrowserProfiles\" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $profileRoot
Write-Host "Fresh browser profiles: $profileRoot"

foreach ($user in $users) {
    $profile = Join-Path $profileRoot $user.key
    $null = New-Item -ItemType Directory -Path $profile
    $loginUrl = $Url.AbsoluteUri.TrimEnd("/") + "/login?login_hint=" +
        [uri]::EscapeDataString([string]$user.userPrincipalName)
    if ($RunId) { $loginUrl += "&run_id=" + [uri]::EscapeDataString($RunId) }
    $privateFlag = if ($Browser -eq "Edge") { "--inprivate" } else { "--incognito" }
    $arguments = @(
        "--user-data-dir=`"$profile`"",
        $privateFlag,
        "--no-first-run",
        "--no-default-browser-check",
        "--new-window",
        "`"$loginUrl`""
    )
    Start-Process -FilePath $BrowserPath -ArgumentList $arguments -ErrorAction Stop
    Write-Host "Opened $($user.key): $($user.userPrincipalName)"
}
Write-Host "Complete Microsoft sign-in, then click 'Start / resume my background Teams messages' for the run."
Write-Host "Close windows rather than signing out while messages are pending."
Write-Host "After closing all these windows, you may manually remove only this profile folder: $profileRoot"
