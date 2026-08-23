# Rasterises icon.svg (and the assets/icons/ adaptive layers) into the PNGs
# referenced by export_presets.cfg — web/PWA icons plus the Android launcher
# and adaptive-icon layers. Re-run after editing any of the SVGs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

# godot.exe is a GUI-subsystem binary: prefer the console build so output shows.
$godot = (Get-Command godot -ErrorAction Stop).Source
$console = Get-ChildItem (Split-Path $godot) -Filter '*console.exe' | Select-Object -First 1
if ($console) { $godot = $console.FullName }

& $godot --headless --path $root -s 'scripts/generate_icons.gd'
if ($LASTEXITCODE -ne 0) { Write-Error "Icon generation failed ($LASTEXITCODE)."; exit 1 }
Write-Host "Icons written to assets/icons/." -ForegroundColor Green
