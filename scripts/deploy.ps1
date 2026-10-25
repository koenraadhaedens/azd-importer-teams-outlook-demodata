$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "aci-deployment.ps1")
foreach ($name in @("WEB_CLIENT_ID", "PUBLIC_HOSTNAME", "WEB_REGISTERED_HOSTNAME")) {
    $value = & azd env get-value $name
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "$name is missing; run azd provision to discover ACI's hostname and register the web app."
    }
    [Environment]::SetEnvironmentVariable($name, ([string]$value).Trim())
}
$hostname = Get-AciHostname
if ($hostname -ne $env:PUBLIC_HOSTNAME -or $hostname -ne $env:WEB_REGISTERED_HOSTNAME) {
    throw "ACI's hostname changed or registration is incomplete. Run azd provision to reconcile Entra before deploying."
}
Invoke-AciDeployment
if ((Get-AciHostname) -ne $hostname) {
    throw "ACI's hostname changed during the update. Run azd provision again; HTTPS readiness is not confirmed."
}
Write-Host "Caddy is requesting/renewing HTTPS for https://$hostname using ACME."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $response = Invoke-WebRequest "https://$hostname/healthz" -TimeoutSec 10
        if ($response.StatusCode -eq 200 -and ($response.Content | ConvertFrom-Json).status -eq "ready") {
            $ready = $true
            break
        }
    } catch {
        Write-Warning "TLS-verified application readiness not yet confirmed (attempt $($i + 1)/30)."
    }
    Start-Sleep -Seconds 10
}
if (-not $ready) {
    throw "HTTPS readiness failed. Check Caddy ACME/CA rate limits, ports 80/443, Azure DNS, runtime Graph roles and managed-identity trust."
}
Write-Host "Application ready: https://$hostname"
