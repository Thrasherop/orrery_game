# Exports a debug-signed APK to build/android/orrery.apk using the "Android" export preset.
# Debug export is used so the APK is signed with the debug keystore and directly installable.
# A release export would require a release keystore configured in the preset.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot

# godot.exe is a GUI-subsystem binary: PowerShell won't wait for it or see its
# exit code. Prefer the console build (*_console.exe) from the same directory.
$godot = (Get-Command godot -ErrorAction Stop).Source
$console = Get-ChildItem (Split-Path $godot) -Filter '*console.exe' | Select-Object -First 1
if ($console) { $godot = $console.FullName }

New-Item -ItemType Directory -Force (Join-Path $root 'build\android') | Out-Null

Write-Host "Exporting Android debug APK..."
& $godot --headless --path $root --export-debug 'Android' 'build/android/orrery.apk'
if ($LASTEXITCODE -ne 0) {
    Write-Error "Android export failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}
Write-Host "APK written to $root\build\android\orrery.apk"
