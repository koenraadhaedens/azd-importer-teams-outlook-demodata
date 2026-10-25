param([string]$Image, [string]$CaddyImage)
$ErrorActionPreference = "Stop"
$images = Get-Content -Raw (Join-Path (Join-Path $PSScriptRoot "..") "config/container-images.json") | ConvertFrom-Json
if (-not $Image) { $Image = $images.services.app.image }
if (-not $CaddyImage) { $CaddyImage = $images.services.caddy.image }
if (-not $Image -or -not $CaddyImage) { throw "Configure both app and Caddy images in config/container-images.json" }
$appId = $null
$caddyId = $null
$smokeScript = Join-Path (Join-Path (Get-Location).Path "tests") "smoke_server.py"
$smokeClient = Join-Path (Join-Path (Get-Location).Path "tests") "smoke_client.py"
$caddyConfig = Join-Path (Get-Location).Path "Caddyfile"
$certificate = Join-Path ([IO.Path]::GetTempPath()) ("demo-loader-ca-" + [guid]::NewGuid() + ".crt")
try {
    $appId = (docker run -d --rm -p 127.0.0.1:8443:443 -p 127.0.0.1:8080:80 `
        --mount "type=bind,source=$smokeScript,target=/checks/smoke_server.py,readonly" `
        $Image python /checks/smoke_server.py).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Application smoke container failed to start" }
    $caddyId = (docker run -d --rm --network "container:$appId" `
        --mount "type=bind,source=$caddyConfig,target=/etc/caddy/Caddyfile,readonly" `
        -e PUBLIC_HOSTNAME=localhost -e ACME_EMAIL=operator@example.org `
        $CaddyImage).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Caddy smoke container failed to start" }
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        docker exec $caddyId test -f /data/caddy/pki/authorities/local/root.crt
        if ($LASTEXITCODE -eq 0) {
            docker cp "${caddyId}:/data/caddy/pki/authorities/local/root.crt" $certificate | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to copy local test CA certificate" }
            $ready = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        docker logs $appId
        docker logs $caddyId
        throw "TLS-verified application readiness failed"
    }
    Start-Sleep -Seconds 3
    python $smokeClient $certificate
    if ($LASTEXITCODE -ne 0) { throw "TLS-verified HTTP checks failed" }
    Write-Host "Python 3.12 image startup + Caddy TLS verification + landing page + HTTPS assets: PASS"
} finally {
    if ($caddyId) { docker stop $caddyId | Out-Null }
    if ($appId) { docker stop $appId | Out-Null }
    if (Test-Path -LiteralPath $certificate) { Remove-Item -LiteralPath $certificate }
}
