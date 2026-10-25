param(
    [Parameter(Mandatory)][string]$Scenario,
    [string]$Users = "config\demo-users.yaml",
    [string]$Resources = "config\resources.yaml"
)
$ErrorActionPreference = "Stop"
python -m demo_loader.cli $Scenario --users $Users --resources $Resources
if ($LASTEXITCODE -ne 0) { throw "Scenario validation failed" }
