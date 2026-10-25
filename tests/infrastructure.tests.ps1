$ErrorActionPreference = "Stop"
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Build-Template {
    param([string]$File)
    $json = & az bicep build --file (Join-Path (Join-Path $PSScriptRoot "..") $File) --stdout
    if ($LASTEXITCODE -ne 0) { throw "Could not compile $File" }
    return ($json -join "`n") | ConvertFrom-Json
}
$main = Build-Template "infra/main.bicep"
$foundation = @($main.resources | Where-Object type -eq "Microsoft.Resources/deployments")[0].properties.template
Assert (-not ($foundation.resources | Where-Object type -like "Microsoft.Storage/*")) "The demo must not provision storage accounts"
Assert (-not ($foundation.resources | Where-Object type -eq "Microsoft.Authorization/roleAssignments")) "No Blob role assignment should remain"
Assert ($main.outputs.AZURE_TENANT_ID.value -eq "[subscription().tenantId]") "Export the selected subscription's tenant"
foreach ($name in @("JOURNAL_BLOB_URL", "AZURE_STORAGE_ACCOUNT_NAME", "AZURE_CERT_STORAGE_NAME")) {
    Assert (-not $main.outputs.PSObject.Properties[$name]) "Obsolete storage output: $name"
}
$aci = Build-Template "infra/aci.bicep"
$group = @($aci.resources | Where-Object type -eq "Microsoft.ContainerInstance/containerGroups")[0]
Assert ($aci.parameters.useManagedIdentityForImagePull.defaultValue -eq $false) "Image pulls must be anonymous by default"
Assert ($group.properties.imageRegistryCredentials -eq "[if(parameters('useManagedIdentityForImagePull'), variables('registryCredentials'), createArray())]") "Use registry credentials only with explicit managed-identity opt-in"
Assert ($group.identity.type -eq "UserAssigned") "Anonymous image pulls must not remove the runtime managed identity"
Assert ($group.properties.ipAddress.type -eq "Public") "Keep the simple public ACI endpoint"
Assert (($group.properties.ipAddress.ports.port | Sort-Object) -join "," -eq "80,443") "Only Caddy's ports should be public"
foreach ($name in @("caddy-data", "journal-data")) {
    $volume = @($group.properties.volumes | Where-Object name -eq $name)
    Assert ($volume.Count -eq 1 -and $volume[0].PSObject.Properties["emptyDir"]) "$name must use an emptyDir"
}
Assert (-not ($group.properties.volumes | Where-Object azureFile)) "No Azure Files mount should remain"
foreach ($name in @("journalBlobUrl", "certificateStorageName")) {
    Assert (-not $aci.parameters.PSObject.Properties[$name]) "Obsolete ACI storage parameter: $name"
}
$app = @($group.properties.containers | Where-Object name -eq "app")[0]
Assert ($app.properties -match "'JOURNAL_BLOB_URL', 'value', ''") "The app must explicitly disable the Blob backend"
Assert ($app.properties -match "'mountPath', '/app/data'") "Mount the local journal for the app"
$caddy = @($group.properties.containers | Where-Object name -eq "https")[0]
Assert (@($caddy.properties.volumeMounts | Where-Object name -eq "journal-data").Count -eq 0) "Caddy must not mount the journal"
$initializer = @($group.properties.initContainers)[0].properties
Assert ($initializer.image -eq $caddy.properties.image) "The initializer must reuse the configured Caddy image"
Assert ($initializer.command[2] -eq "chown 10001:10001 /journal; chmod 700 /journal") "Initialize the nonroot journal permissions"
Assert ($initializer.volumeMounts[0].name -eq "journal-data") "Only initialize the journal volume"
Write-Host "PASS: no Azure storage resources/mounts, temporary isolated volumes, nonroot permissions and unchanged public Caddy ingress."
