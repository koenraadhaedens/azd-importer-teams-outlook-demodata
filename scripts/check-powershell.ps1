$ErrorActionPreference = "Stop"
$failed = $false
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.ps1") {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Error -Message "$($file.Name): $errors" -ErrorAction Continue
    }
}
if ($failed) { throw "PowerShell syntax validation failed" }
Write-Host "All PowerShell scripts parse successfully."
