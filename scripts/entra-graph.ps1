function Invoke-Graph {
    param([string]$Method, [string]$Path, [object]$Body)
    $file = $null
    try {
        $arguments = @("rest", "--method", $Method, "--url", "https://graph.microsoft.com/v1.0/$Path",
            "--only-show-errors", "--output", "json")
        if ($env:AZURE_SUBSCRIPTION_ID) {
            $arguments += @("--subscription", $env:AZURE_SUBSCRIPTION_ID)
        }
        if ($null -ne $Body) {
            $file = Join-Path ([IO.Path]::GetTempPath()) ("entra-" + [guid]::NewGuid() + ".json")
            $Body | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 $file
            $arguments += @("--headers", "Content-Type=application/json", "--body", "@$file")
        }
        $result = & az @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Graph $Method $Path failed. Check the deployment identity's preauthorized Graph permissions; no interactive login, consent or elevation fallback is attempted."
        }
        if ($result) { return ($result -join "`n") | ConvertFrom-Json }
    } finally {
        if ($file) { Remove-Item -LiteralPath $file -Force }
    }
}
