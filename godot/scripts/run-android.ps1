# Builds the debug APK, installs it on a connected device via adb, launches it,
# and tails the Godot log output. Ctrl+C stops the log tail (the game keeps running).
param(
    # adb serial to target (e.g. "10.0.0.193:38113"). Defaults to the only connected device.
    [string]$Serial,
    [switch]$SkipBuild,
    [switch]$NoLogcat
)
$ErrorActionPreference = 'Stop'
$package = 'com.ultra.orrery'
$root = Split-Path $PSScriptRoot
$apk = Join-Path $root 'build\android\orrery.apk'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-android.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if (-not $Serial) {
    $devices = @(& adb devices | Select-String "`tdevice$" | ForEach-Object { ($_ -split "`t")[0] })
    if ($devices.Count -eq 0) {
        Write-Error "No device connected. Plug in via USB or run: adb connect <phone-ip>:<port>"
        exit 1
    }
    if ($devices.Count -gt 1) {
        Write-Error "Multiple devices connected ($($devices -join ', ')). Pass -Serial <serial>."
        exit 1
    }
    $Serial = $devices[0]
}

Write-Host "Installing on $Serial..."
& adb -s $Serial install -r $apk
if ($LASTEXITCODE -ne 0) {
    Write-Error "adb install failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

Write-Host "Launching $package..."
& adb -s $Serial shell monkey -p $package -c android.intent.category.LAUNCHER 1 | Out-Null

if (-not $NoLogcat) {
    Write-Host "Tailing Godot log output (Ctrl+C to stop)..."
    & adb -s $Serial logcat -T 1 -s godot:* GodotEngine:* AndroidRuntime:E
}
