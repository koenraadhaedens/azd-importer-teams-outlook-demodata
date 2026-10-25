param(
    [Parameter(Mandatory)][string]$Scenario,
    [string]$Users = "config\demo-users.json",
    [string]$Resources = "config\resources.json"
)
$ErrorActionPreference = "Stop"
python -m demo_loader.cli $Scenario --users $Users --resources $Resources
if ($LASTEXITCODE -ne 0) { throw "Scenario validation failed" }
