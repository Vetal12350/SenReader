# One-time trusted, local-only SenReader signing setup for Windows.
# This script MUST run outside the Codex model/worker subprocess.
# It never prints passwords or private key material and never commits them.
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Configure,
    [string]$KeystorePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repo = "Vetal12350/SenReader"
$alias = "senreader"
$required = @(
    "SENREADER_SIGNING_KEY_BASE64",
    "SENREADER_SIGNING_STORE_PASSWORD",
    "SENREADER_SIGNING_ALIAS",
    "SENREADER_SIGNING_KEY_PASSWORD"
)

if ($CheckOnly -eq $Configure) {
    throw "Specify exactly one of -CheckOnly or -Configure."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Install it, then run gh auth login."
}
& gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "gh auth is not configured for this computer." }

# Only non-secret names are returned by GitHub; values cannot be inspected.
$json = & gh secret list --repo $repo --app actions --json name
if ($LASTEXITCODE -ne 0) { throw "Cannot read GitHub Actions secret names." }
$existing = @()
if ($json) { $existing = @(($json | ConvertFrom-Json) | ForEach-Object { $_.name }) }
$present = @($required | Where-Object { $_ -in $existing })
$missing = @($required | Where-Object { $_ -notin $existing })
Write-Host ("SenReader GitHub Actions secrets: {0}/4 configured by name." -f $present.Count)
foreach ($name in $required) {
    Write-Host ("  {0}: {1}" -f $name, $(if ($name -in $existing) { "present" } else { "missing" }))
}

if ($CheckOnly) {
    Write-Host "This checks secret NAMES only, not their values or the actual APK certificate."
    exit 0
}

# Never rotate an existing signing identity as part of automatic setup.
if ($present.Count -gt 0) {
    throw "One or more signing secrets already exist. Refusing to overwrite or rotate a possibly active signing identity. Inspect the configuration manually."
}
if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    throw "JDK keytool is required; install JDK 17 or newer."
}
if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    throw "Pass -KeystorePath pointing to a private location OUTSIDE the repository."
}
$full = [System.IO.Path]::GetFullPath($KeystorePath)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ($full.StartsWith($repoRoot.TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "A signing keystore must never be created inside the Git repository."
}
$parent = [System.IO.Path]::GetDirectoryName($full)
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "Create a private directory for your keystore first: $parent"
}
if (Test-Path -LiteralPath $full) {
    Write-Host "Using existing keystore file; will not overwrite it."
} else {
    Write-Host "Creating local keystore interactively. Enter a NEW strong password in keytool prompts."
    Write-Host "For PKCS12, press Enter to use the same password for the key when prompted."
    & keytool -genkeypair -keystore $full -storetype PKCS12 -alias $alias -keyalg RSA -keysize 3072 -validity 10000
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $full)) {
        throw "Keystore generation failed."
    }
}
Write-Host "Checking local keystore alias; keytool may ask for its password."
& keytool -list -keystore $full -alias $alias
if ($LASTEXITCODE -ne 0) { throw "Keystore validation failed; no GitHub secrets uploaded." }
Write-Host "IMPORTANT: Back up the keystore and its passwords offline. Losing them breaks future APK upgrades."
$approved = Read-Host "Type SIGN to upload four secrets to GitHub; anything else cancels"
if ($approved -cne "SIGN") { throw "Cancelled without uploading secrets." }

function Read-SecretText([string]$prompt) {
    $secure = Read-Host $prompt -AsSecureString
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

# Write directly to gh stdin. Secrets never appear in arguments, files,
# clipboard, logs, or Codex/Worker prompts.
function Set-ActionSecret([string]$name, [string]$value) {
    if ([string]::IsNullOrEmpty($value)) { throw "Empty value for $name." }
    $binary = (Get-Command gh).Source
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $binary
    $info.Arguments = "secret set $name --repo Vetal12350/SenReader --app actions"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Cannot start GitHub CLI." }
        $process.StandardInput.Write($value)
        $process.StandardInput.Close()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "GitHub refused secret $name." }
    } finally {
        $process.Dispose()
    }
}

$storePass = Read-SecretText "Enter the existing keystore password (private)"
$keyPass = Read-SecretText "Enter the private key password (usually the same)"
if ([string]::IsNullOrEmpty($storePass) -or [string]::IsNullOrEmpty($keyPass)) {
    throw "Passwords cannot be empty; no GitHub secrets uploaded."
}
$encodedKey = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full))
# Upload the key first. Failure leaves partial config; a retry is deliberately
# blocked until reviewed to prevent accidental key replacement.
Set-ActionSecret "SENREADER_SIGNING_KEY_BASE64" $encodedKey
Set-ActionSecret "SENREADER_SIGNING_STORE_PASSWORD" $storePass
Set-ActionSecret "SENREADER_SIGNING_ALIAS" $alias
Set-ActionSecret "SENREADER_SIGNING_KEY_PASSWORD" $keyPass
$encodedKey = $null
$storePass = $null
$keyPass = $null
Write-Host "Four signing secret values uploaded; this does NOT verify the release signature."
Write-Host "Now run GitHub Actions on main and verify that the RELEASE APK is signed and installs as expected."
