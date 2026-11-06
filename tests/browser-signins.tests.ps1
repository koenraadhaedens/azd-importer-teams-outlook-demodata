$ErrorActionPreference = "Stop"
$launches = [System.Collections.Generic.List[object]]::new()
$failLaunch = $false
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Start-Process {
    param($FilePath, $ArgumentList, $ErrorAction)
    if ($failLaunch) { throw "Browser launch failed" }
    $launches.Add(@{ FilePath = $FilePath; Arguments = $ArgumentList })
}
$helper = Join-Path (Join-Path $PSScriptRoot "..") "scripts\open-teams-signins.ps1"
$fixture = Join-Path ([IO.Path]::GetTempPath()) ("demo-browser-tests-" + [guid]::NewGuid())
$originalLocalAppData = $env:LOCALAPPDATA
$originalOS = $env:OS
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $env:LOCALAPPDATA = $fixture
    # Mock browser launches on CI's Linux host as well as on Windows.
    $env:OS = "Windows_NT"
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\config\config.json") -Raw |
        ConvertFrom-Json
    $config.'x-demo'.users[0].userPrincipalName = "adele+demo@example.org"
    $configPath = Join-Path $fixture "config.json"
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
    $options = @{
        Url = "https://demo.example.org"
        Config = $configPath
        BrowserPath = $helper
        RunId = "test-run"
    }
    & $helper @options -UserKeys adele,alex
    Assert ($launches.Count -eq 2) "Launch only selected authors"
    $profiles = @($launches | ForEach-Object { $_.Arguments[0] })
    Assert ($profiles[0] -ne $profiles[1]) "Each author must have a different user-data directory"
    Assert ($launches[0].Arguments[-1] -eq
        '"https://demo.example.org/login?login_hint=adele%2Bdemo%40example.org&run_id=test-run"') "Encode username and preserve run destination"
    Assert ("--inprivate" -in $launches[0].Arguments) "Use Edge private mode"
    Assert ($profiles[0] -match '^--user-data-dir=".+adele"$') "Quote the profile path"

    $options.Remove("RunId")
    & $helper @options -UserKeys adele -Browser Chrome
    Assert ("--incognito" -in $launches[2].Arguments) "Use Chrome private mode"
    Assert ($profiles[0] -ne $launches[2].Arguments[0]) "Do not reuse previous invocation's cookies"
    Assert ($launches[2].Arguments[-1] -notmatch "run_id") "Run destination is optional"

    foreach ($invalid in @(
        @{ UserKeys = @("unknown") },
        @{ Url = "http://demo.example.org" },
        @{ Url = "https://demo.example.org/runs/example" },
        @{ Url = "https://demo.example.org/?unexpected=1" },
        @{ RunId = "../elsewhere" }
    )) {
        $arguments = $options.Clone()
        foreach ($key in $invalid.Keys) { $arguments[$key] = $invalid[$key] }
        $rejected = $false
        try { & $helper @arguments } catch { $rejected = $true }
        Assert $rejected "Reject invalid options before launching a browser"
    }
    Assert ($launches.Count -eq 3) "Invalid input must not launch browsers"
    $failLaunch = $true
    $rejected = $false
    try { & $helper @options -UserKeys adele } catch { $rejected = $_ -match "Browser launch failed" }
    Assert $rejected "Surface browser launch errors"
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:OS = $originalOS
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Browser sign-in tests passed."
