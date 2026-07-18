# Builds the debug APK, installs it on a connected device via adb, launches it,
# and tails the Godot log output. Ctrl+C stops the log tail (the game keeps running).
#
# adb-server note: use the SAME adb you connect with. If Godot's export (which
# uses the SDK's adb) is a different VERSION than your adb, it will kill your
# adb server mid-build and drop the device ("daemon not running; starting
# now"). To avoid the kill entirely, align the versions (e.g. update the SDK's
# platform-tools to match, or point Godot's export/android/adb setting at your
# adb). Either way this script captures the device before the build and
# reconnects a WiFi device (serial "ip:port") afterwards.
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

# --- Resolve adb: prefer the one on PATH (the adb you connect with, so we talk
#     to the server that owns your device), fall back to the SDK's. ---
$adb = $null
$pathAdb = Get-Command adb -ErrorAction SilentlyContinue
if ($pathAdb) { $adb = $pathAdb.Source }
if (-not $adb) {
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
           elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
           else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $sdkAdb = Join-Path $sdk 'platform-tools\adb.exe'
    if (Test-Path $sdkAdb) { $adb = $sdkAdb } else { $adb = 'adb' }
}

function Get-AdbDevices {
    # non-fatal: a failed adb call shouldn't terminate the script
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $adb devices 2>$null
    $ErrorActionPreference = $prev
    @($out | Select-String "`tdevice$" | ForEach-Object { ($_ -split "`t")[0] })
}

# --- Capture the target BEFORE building (the export can restart the adb server
#     and drop a WiFi device; we reconnect it afterwards) ---
& $adb start-server *> $null
if (-not $Serial) {
    $before = Get-AdbDevices
    if ($before.Count -eq 1) { $Serial = $before[0] }
    elseif ($before.Count -gt 1) {
        Write-Error "Multiple devices connected ($($before -join ', ')). Pass -Serial <serial>."
        exit 1
    }
}

# --- Build ---
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-android.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# --- Reconnect a WiFi device the build may have dropped ---
& $adb start-server *> $null
$devices = Get-AdbDevices
if ($Serial -and ($Serial -notin $devices) -and ($Serial -match ':')) {
    Write-Host "Reconnecting $Serial (adb server was restarted during the build)..."
    & $adb connect $Serial *> $null
    $devices = Get-AdbDevices
}

# --- Resolve / verify the target ---
if (-not $Serial) {
    if ($devices.Count -eq 0) {
        Write-Error "No device connected. Plug in via USB or run: `"$adb`" connect <phone-ip>:<port>"
        exit 1
    }
    if ($devices.Count -gt 1) {
        Write-Error "Multiple devices connected ($($devices -join ', ')). Pass -Serial <serial>."
        exit 1
    }
    $Serial = $devices[0]
}
if ($Serial -notin $devices) {
    Write-Error "Device $Serial is not connected. For WiFi run: `"$adb`" connect $Serial"
    exit 1
}

Write-Host "Installing on $Serial..."
& $adb -s $Serial install -r $apk
if ($LASTEXITCODE -ne 0) {
    Write-Error "adb install failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

Write-Host "Launching $package..."
& $adb -s $Serial shell monkey -p $package -c android.intent.category.LAUNCHER 1 | Out-Null

if (-not $NoLogcat) {
    Write-Host "Tailing Godot log output (Ctrl+C to stop)..."
    & $adb -s $Serial logcat -T 1 -s godot:* GodotEngine:* AndroidRuntime:E
}
