function Write-PrivateJsonFile {
    param([string]$Path, [object]$Value)
    $options = [IO.FileStreamOptions]::new()
    $options.Mode = [IO.FileMode]::CreateNew
    $options.Access = [IO.FileAccess]::Write
    $options.Share = [IO.FileShare]::None
    if (-not $IsWindows) {
        $options.UnixCreateMode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
    }
    if ($IsWindows) {
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $permissions = [Security.AccessControl.FileSecurity]::new()
        $permissions.SetOwner($user)
        $permissions.SetAccessRuleProtection($true, $false)
        $permissions.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $user, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
        $stream = [IO.FileSystemAclExtensions]::Create(
            [IO.FileInfo]::new($Path), [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
            4096, [IO.FileOptions]::None, $permissions)
    } else {
        $stream = [IO.FileStream]::new($Path, $options)
    }
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($Value | ConvertTo-Json -Depth 20)) } finally { $writer.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Read-DeploymentConfiguration {
    param([string]$Path = $env:DEMO_CONFIG_FILE)
    if (-not $Path) { $Path = Join-Path (Join-Path $PSScriptRoot "..") "config/config.local.json" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Private configuration is missing. Run scripts/setup.ps1 -Stage Configure first."
    }
    $configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $users = @($configuration.'x-demo'.users)
    if ($users.Count -ne 5 -or
        @($users | Where-Object {
            $_.key -notmatch '^[a-z][a-z0-9_-]{0,39}$' -or
            [string]::IsNullOrWhiteSpace($_.displayName) -or
            $_.userPrincipalName -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$' -or
            $_.userPrincipalName -like '*@contoso.onmicrosoft.com'
        }).Count -gt 0 -or
        @($users.key | Sort-Object -Unique).Count -ne 5 -or
        @($users.userPrincipalName | Sort-Object -Unique).Count -ne 5) {
        throw "Configure five distinct real demo-user keys, display names and UPNs in x-demo.users; do not deploy template users."
    }
    if ($null -eq $configuration.'x-demo'.channels -or
        $configuration.'x-demo'.channels -isnot [pscustomobject]) {
        throw "Configure x-demo.channels as a JSON object (empty is allowed for email-only scenarios)."
    }
    foreach ($channel in $configuration.'x-demo'.channels.PSObject.Properties) {
        $teamId = [guid]::Empty
        if ($channel.Name -notmatch '^[a-z][a-z0-9_-]{0,39}$' -or
            -not [guid]::TryParse([string]$channel.Value.teamId, [ref]$teamId) -or
            $channel.Value.channelId -notmatch '^19:[A-Za-z0-9_.@:-]{1,250}$') {
            throw "Channel aliases require a valid key, team UUID and Teams channel ID."
        }
    }
    foreach ($name in @("app", "caddy")) {
        if ($configuration.services.$name.image -notmatch '^[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?/[a-z0-9]+(?:[._/-][a-z0-9]+)*(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?$') {
            throw "Configure fully qualified published services.$name.image in the private configuration."
        }
    }
    if ($configuration.'x-setup'.acmeEmail -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
        throw "Configure x-setup.acmeEmail in the private configuration for certificate notices."
    }
    $excluded = [string]$configuration.'x-setup'.outOfScopeTestUpn
    if ($excluded -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$' -or $excluded -in $users.userPrincipalName) {
        throw "Configure x-setup.outOfScopeTestUpn as an existing sixth mailbox, not a demo user."
    }
    return $configuration
}
