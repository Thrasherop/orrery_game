# Builds the debug APK, installs it on a connected device via adb, launches it,
# and tails the Godot log output. Ctrl+C stops the log tail (the game keeps running).
#
# adb-server notes (both of these drop your device mid-run):
#  1. Godot's export leaves NO adb server running when it exits, so the device
#     is always gone by install time. Nothing prevents this -- we just wait for
#     the device to come back, re-issuing `adb connect` for WiFi serials.
#  2. Only ONE adb server runs at a time, and a client whose version differs
#     from the running server kills it and starts its own. Godot polls devices
#     with the adb from ITS configured SDK, so this script uses that same adb
#     (read from Godot's editor settings) and warns if the adb on your PATH --
#     the one you probably ran `adb connect` with -- is a different version.
param(
    # adb serial to target (e.g. "10.0.0.193:38113"). Defaults to the only connected device.
    [string]$Serial,
    [switch]$SkipBuild,
    [switch]$NoLogcat,
    # How long to wait for the device to come back after the build.
    [int]$DeviceTimeoutSec = 45
)
$ErrorActionPreference = 'Stop'
$package = 'com.ultra.orrery'
$root = Split-Path $PSScriptRoot
$apk = Join-Path $root 'build\android\orrery.apk'

# --- Resolve adb -------------------------------------------------------
# Prefer the adb belonging to the SDK Godot exports with, so the two never
# fight over the server.
function Get-GodotSdkPath {
    $dir = Join-Path $env:APPDATA 'Godot'
    if (-not (Test-Path $dir)) { return $null }
    $files = @(Get-ChildItem $dir -Filter 'editor_settings-*.tres' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending)
    foreach ($f in $files) {
        $hit = Select-String -Path $f.FullName -Pattern '^export/android/android_sdk_path\s*=\s*"(.*)"' |
               Select-Object -First 1
        if ($hit) {
            # .tres escapes backslashes (and quotes) C-style
            $p = [Regex]::Unescape($hit.Matches[0].Groups[1].Value)
            if ($p -and (Test-Path $p)) { return $p }
        }
    }
    return $null
}

$adb = $null
$sdk = Get-GodotSdkPath
if (-not $sdk) {
    if ($env:ANDROID_HOME) { $sdk = $env:ANDROID_HOME }
    elseif ($env:ANDROID_SDK_ROOT) { $sdk = $env:ANDROID_SDK_ROOT }
    else { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
}
$sdkAdb = Join-Path $sdk 'platform-tools\adb.exe'
if (Test-Path $sdkAdb) { $adb = $sdkAdb }
if (-not $adb) {
    $pathAdb = Get-Command adb -ErrorAction SilentlyContinue
    if ($pathAdb) { $adb = $pathAdb.Source } else { $adb = 'adb' }
}

# --- adb invocation ----------------------------------------------------
# PowerShell 5.1 turns a native command's stderr into ErrorRecords, which are
# TERMINATING under $ErrorActionPreference='Stop' -- so adb's harmless "daemon
# not running; starting now" would kill this script. Every adb call goes
# through here: stderr is merged into the returned lines and success is judged
# by the exit code, left in $script:AdbExit.
$script:AdbExit = 0
function Invoke-Adb([string[]]$AdbArgs, [string]$Exe) {
    if (-not $Exe) { $Exe = $adb }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @AdbArgs 2>&1
        $script:AdbExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    # ErrorRecords stringify back to the original stderr lines
    @($out | ForEach-Object { "$_" })
}

function Get-AdbVersion([string]$exe) {
    $hit = Invoke-Adb @('version') $exe | Select-String -Pattern '^Version\s+(\S+)' | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
    return $null
}

# Warn if the adb on PATH (the one you likely ran `adb connect` with) is a
# different version -- it will fight this one over the server.
$pathAdbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($pathAdbCmd -and ($pathAdbCmd.Source -ne $adb)) {
    $ours = Get-AdbVersion $adb
    $theirs = Get-AdbVersion $pathAdbCmd.Source
    if ($ours -and $theirs -and ($ours -ne $theirs)) {
        Write-Warning "adb version mismatch: PATH adb is $theirs ($($pathAdbCmd.Source)), Godot's SDK adb is $ours ($adb)."
        Write-Warning "Whichever runs second kills the other's server and drops WiFi devices. This script uses Godot's."
        Write-Warning "Permanent fix: make them the same build (update the SDK's platform-tools, or put it first on PATH)."
    }
}
Write-Host "Using adb: $adb"

# NOTE: always call this as @(Get-AdbDevices) -- PowerShell unwraps a
# single-element array on return, and indexing the resulting string would hand
# back its first CHARACTER instead of the serial.
function Get-AdbDevices {
    @(Invoke-Adb @('devices') | Select-String "`tdevice$" | ForEach-Object { ($_ -split "`t")[0] })
}

# A network serial is either "ip:port" or an mDNS wireless-debugging name like
# "adb-RFCY6158LQF-epwk4Q._adb-tls-connect._tcp" (no colon in that one -- don't
# test for ':' alone). USB serials are neither, and come back on their own once
# the server restarts.
function Test-NetworkSerial([string]$serial) {
    return ($serial -match ':') -or ($serial -match '\._tcp\.?$')
}

# Poll until $serial shows up as "device", re-issuing `adb connect` for network
# serials (a freshly restarted server needs a few tries, and a device can sit
# in "offline" for a second or two before it is usable).
function Wait-ForDevice([string]$serial, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $announced = $false
    while ($true) {
        $devices = @(Get-AdbDevices)
        if ($serial) {
            if ($devices -contains $serial) { return $devices }
        }
        elseif ($devices.Count -gt 0) { return $devices }

        if ((Get-Date) -gt $deadline) { return $devices }

        if (-not $announced) {
            $what = if ($serial) { $serial } else { 'a device' }
            Write-Host "Waiting for $what to come back (the export shuts the adb server down)..."
            $announced = $true
        }
        if ($serial -and (Test-NetworkSerial $serial)) { Invoke-Adb @('connect', $serial) | Out-Null }
        Start-Sleep -Seconds 1
    }
}

# --- Capture the target BEFORE building, and fail fast if there is none
#     (better than discovering it after a multi-minute build) -------------
Invoke-Adb @('start-server') | Out-Null
$before = @(Get-AdbDevices)
if (-not $Serial) {
    if ($before.Count -eq 0) {
        Write-Error "No device connected. Plug in via USB or run: `"$adb`" connect <phone-ip>:<port>"
        exit 1
    }
    if ($before.Count -gt 1) {
        Write-Error "Multiple devices connected ($($before -join ', ')). Pass -Serial <serial>."
        exit 1
    }
    $Serial = $before[0]
}
elseif ($before -notcontains $Serial) {
    Write-Warning "$Serial is not connected yet; will try to reach it after the build."
}
Write-Host "Target device: $Serial"

# --- Build ---
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-android.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# --- Wait out the adb server the export just killed ---------------------
Invoke-Adb @('start-server') | Out-Null
$devices = @(Wait-ForDevice $Serial $DeviceTimeoutSec)
if ($devices -notcontains $Serial) {
    $seen = if ($devices.Count) { $devices -join ', ' } else { '(none)' }
    Write-Error "Device $Serial never came back after $DeviceTimeoutSec s (connected: $seen). For WiFi run: `"$adb`" connect $Serial"
    exit 1
}

if (-not (Test-Path $apk)) {
    Write-Error "APK not found at $apk. Run without -SkipBuild."
    exit 1
}

Write-Host "Installing on $Serial..."
Invoke-Adb @('-s', $Serial, 'install', '-r', $apk) | Write-Host
if ($script:AdbExit -ne 0) {
    Write-Error "adb install failed (exit $script:AdbExit)."
    exit $script:AdbExit
}

Write-Host "Launching $package..."
Invoke-Adb @('-s', $Serial, 'shell', 'monkey', '-p', $package, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null

if (-not $NoLogcat) {
    Write-Host "Tailing Godot log output (Ctrl+C to stop)..."
    # streamed live, not buffered, so it is invoked directly (with stderr
    # de-fanged the same way Invoke-Adb does it)
    $ErrorActionPreference = 'Continue'
    & $adb -s $Serial logcat -T 1 -s godot:* GodotEngine:* AndroidRuntime:E
}
