# Exports a debug-signed APK to build/android/orrery.apk using the "Android"
# export preset, INCLUDING the native arm64 GDExtension kernel (.so). Requires
# the Android NDK + a godot-cpp checkout in native/ (see native/README.md).
# Debug export signs with the debug keystore for direct install.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$native = Join-Path $root 'native'

# --- 1. Locate the Android NDK ------------------------------------------
$ndk = $env:ANDROID_NDK_HOME
if (-not $ndk) { $ndk = $env:ANDROID_NDK_ROOT }
if (-not $ndk) {
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $ndkBase = Join-Path $sdk 'ndk'
    if (Test-Path $ndkBase) {
        $ndk = (Get-ChildItem $ndkBase -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
}
if (-not $ndk -or -not (Test-Path (Join-Path $ndk 'build\cmake\android.toolchain.cmake'))) {
    Write-Error "Android NDK not found. Install it or set `$env:ANDROID_NDK_HOME (see native/README.md)."
    exit 1
}
Write-Host "Using NDK: $ndk"

if (-not (Test-Path (Join-Path $native 'godot-cpp'))) {
    Write-Error "godot-cpp not found in native/godot-cpp. Clone it first (see native/README.md)."
    exit 1
}

# --- 2. Build the native GDExtension (.so) for arm64-v8a ----------------
$abi = 'arm64-v8a'
$buildDir = "build-android-$abi"
# forward slashes so CMake is happy regardless of how it's re-quoted
$toolchain = (Join-Path $ndk 'build\cmake\android.toolchain.cmake') -replace '\\', '/'
Push-Location $native
try {
    Write-Host "Building native GDExtension for android/$abi..."
    # Array-splat the args (no backtick line-continuation — that silently drops
    # arguments in PowerShell and produced "Invalid Android ABI").
    $cfgArgs = @(
        '-S', '.', '-B', $buildDir, '-G', 'Ninja',
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
        "-DANDROID_ABI=$abi",
        '-DANDROID_PLATFORM=android-24',
        '-DANDROID_STL=c++_static',
        '-DCMAKE_BUILD_TYPE=Release',
        "-DORRERY_OUTPUT_NAME=orrery_native.android.$abi"
    )
    & cmake @cfgArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed (exit $LASTEXITCODE)." }
    & cmake --build $buildDir -j
    if ($LASTEXITCODE -ne 0) { throw "Native build failed (exit $LASTEXITCODE)." }
}
finally { Pop-Location }

# --- 3. Export the APK --------------------------------------------------
# godot.exe is a GUI-subsystem binary: PowerShell won't wait for it or see its
# exit code. Prefer the console build (*_console.exe) from the same directory.
$godot = (Get-Command godot -ErrorAction Stop).Source
$console = Get-ChildItem (Split-Path $godot) -Filter '*console.exe' | Select-Object -First 1
if ($console) { $godot = $console.FullName }

New-Item -ItemType Directory -Force (Join-Path $root 'build\android') | Out-Null
Write-Host "Exporting Android debug APK..."
# Godot may print non-fatal ERROR lines to stderr (e.g. "No project icon");
# under 'Stop' PowerShell would treat those as terminating. Judge success by
# the exit code instead.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $godot --headless --path $root --export-debug 'Android' 'build/android/orrery.apk'
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEAP
if ($code -ne 0) {
    Write-Error "Android export failed (exit $code)."
    exit $code
}
Write-Host "APK (with native arm64 kernel) written to $root\build\android\orrery.apk"
