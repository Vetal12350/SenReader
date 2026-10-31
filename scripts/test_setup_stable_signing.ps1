# Syntax-only check. Safe in CI: never executes signing helper or accesses secrets.
$ErrorActionPreference = "Stop"
$target = Join-Path $PSScriptRoot "setup_stable_signing.ps1"
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $target, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    foreach ($item in $errors) {
        Write-Error ("Signing script syntax error at line {0}: {1}" -f
            $item.Extent.StartLineNumber, $item.Message)
    }
    exit 1
}
Write-Host "Signing script syntax is valid (no secrets used)."
