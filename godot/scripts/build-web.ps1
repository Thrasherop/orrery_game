# Exports a release web build to build/web/ using the "Web" export preset.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

# godot.exe is a GUI-subsystem binary: PowerShell won't wait for it or see its
# exit code. Prefer the console build (*_console.exe) from the same directory.
$godot = (Get-Command godot -ErrorAction Stop).Source
$console = Get-ChildItem (Split-Path $godot) -Filter '*console.exe' | Select-Object -First 1
if ($console) { $godot = $console.FullName }

New-Item -ItemType Directory -Force (Join-Path $root 'build\web') | Out-Null

Write-Host "Exporting web build..."
& $godot --headless --path $root --export-release 'Web' 'build/web/index.html'
if ($LASTEXITCODE -ne 0) {
    Write-Error "Web export failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}
Write-Host "Web build written to $root\build\web"
