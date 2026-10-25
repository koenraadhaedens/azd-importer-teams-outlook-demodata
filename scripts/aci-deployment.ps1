function Invoke-Azure {
    param([string[]]$Arguments)
    if ($env:AZURE_SUBSCRIPTION_ID) {
        $Arguments += @("--subscription", $env:AZURE_SUBSCRIPTION_ID)
    }
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI operation failed: $($Arguments[0]). Check permissions, registry pull authorization and resource availability."
    }
    return $result
}

function Get-AciContainer {
    $groups = Invoke-Azure @("container", "list", "--resource-group", $env:AZURE_RESOURCE_GROUP,
        "--output", "json", "--only-show-errors")
    $matches = @(($groups -join "`n" | ConvertFrom-Json) | Where-Object name -eq $env:ACI_NAME)
    if ($matches.Count -gt 1) { throw "Ambiguous ACI container group name." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-AciHostname {
    $value = Invoke-Azure @("container", "show", "-g", $env:AZURE_RESOURCE_GROUP, "-n", $env:ACI_NAME,
        "--query", "ipAddress.fqdn", "--output", "tsv", "--only-show-errors")
    $hostname = ([string]($value -join "")).Trim().ToLowerInvariant()
    if ($hostname -notmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.azurecontainer\.io$') {
        throw "ACI did not return a valid public Azure FQDN; fix container provisioning before registration."
    }
    return $hostname
}

function Invoke-AciDeployment {
    param([switch]$Bootstrap)
    foreach ($name in @("AZURE_RESOURCE_GROUP", "AZURE_IDENTITY_RESOURCE_ID", "AZURE_IDENTITY_CLIENT_ID",
        "ACI_NAME", "ACI_DNS_LABEL", "AZURE_LOG_WORKSPACE_NAME",
        "ACME_EMAIL", "OPERATOR_IDS", "AZURE_TENANT_ID")) {
        if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing azd environment value: $name" }
    }
    if ($env:ACI_NAME -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw "Invalid ACI_NAME." }
    if ($env:ACME_EMAIL -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
        throw "ACME_EMAIL must be a valid administrative email address."
    }
    if ($env:DEMO_TENANT_CONFIRMED -ne "true") { throw "Isolated demo tenant confirmation is required." }
    $null = [guid]::Parse($env:AZURE_TENANT_ID)
    foreach ($id in @($env:OPERATOR_IDS | ConvertFrom-Json)) { $null = [guid]::Parse($id) }
    if (-not $Bootstrap) {
        $null = [guid]::Parse($env:WEB_CLIENT_ID)
        if ($env:PUBLIC_HOSTNAME -notmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.azurecontainer\.io$') {
            throw "Run azd provision to discover ACI's HTTPS hostname before deployment."
        }
    }
    $parameters = @{
        containerGroupName = @{ value = $env:ACI_NAME }
        dnsLabel = @{ value = $env:ACI_DNS_LABEL }
        publicHostname = @{ value = $(if ($Bootstrap) { "" } else { $env:PUBLIC_HOSTNAME }) }
        acmeEmail = @{ value = $env:ACME_EMAIL }
        identityResourceId = @{ value = $env:AZURE_IDENTITY_RESOURCE_ID }
        identityClientId = @{ value = $env:AZURE_IDENTITY_CLIENT_ID }
        tenantId = @{ value = $env:AZURE_TENANT_ID }
        webClientId = @{ value = $(if ($Bootstrap) { "" } else { $env:WEB_CLIENT_ID }) }
        bootstrap = @{ value = [bool]$Bootstrap }
        logWorkspaceName = @{ value = $env:AZURE_LOG_WORKSPACE_NAME }
        operatorIds = @{ value = $env:OPERATOR_IDS }
        authorizedGroupId = @{ value = $(if ($env:AUTHORIZED_GROUP_ID) { $env:AUTHORIZED_GROUP_ID } else { "" }) }
        deliveryEnabled = @{ value = (-not $Bootstrap -and $env:DELIVERY_ENABLED -eq "true") }
        mailboxScopeConfirmed = @{ value = ($env:MAILBOX_SCOPE_CONFIRMED -eq "true") }
        allowExternalRecipients = @{ value = ($env:ALLOW_EXTERNAL_RECIPIENTS -eq "true") }
    }
    $file = Join-Path ([IO.Path]::GetTempPath()) ("aci-" + [guid]::NewGuid() + ".json")
    try {
        Write-Warning "Demo-only temporary storage: ACI stop/restart/update/recreation can discard certificates and execution history. Review prior sends before running scenarios after storage loss."
        @{
            '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
            contentVersion = "1.0.0.0"
            parameters = $parameters
        } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $file
        $template = Join-Path (Join-Path $PSScriptRoot "..") "infra/aci.bicep"
        Invoke-Azure @("deployment", "group", "create", "--resource-group", $env:AZURE_RESOURCE_GROUP,
            "--name", "aci-app", "--template-file", $template, "--parameters", "@$file",
            "--output", "none", "--only-show-errors") | Out-Null
    } finally {
        Remove-Item -LiteralPath $file -Force
    }
}
