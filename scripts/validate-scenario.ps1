param(
    [Parameter(Mandatory)][string]$Scenario,
    [string]$Config = "config\config.local.json"
)
$ErrorActionPreference = "Stop"
python -m demo_loader.cli $Scenario --config $Config
if ($LASTEXITCODE -ne 0) { throw "Scenario validation failed" }
