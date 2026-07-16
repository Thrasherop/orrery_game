# Builds the web export, serves it on http://localhost:8060, and opens the browser.
# Ctrl+C stops the server.
param(
    [int]$Port = 8060,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-web.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$webDir = Join-Path $root 'build\web'
if (-not (Test-Path (Join-Path $webDir 'index.html'))) {
    Write-Error "No web build found at $webDir. Run scripts\build-web.ps1 first."
    exit 1
}

Write-Host "Serving $webDir at http://localhost:$Port (Ctrl+C to stop)"
Start-Process "http://localhost:$Port"
& python -m http.server $Port --directory $webDir
