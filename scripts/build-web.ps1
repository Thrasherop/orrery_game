# Exports a release web build to build/web/, INCLUDING the native WASM physics
# kernel (nbody.js + nbody.wasm) that the game loads at runtime via
# JavaScriptBridge. The desktop GDExtension is excluded from the web preset;
# on web the sim uses the WASM module, falling back to GDScript if it fails.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$native = Join-Path $root 'native'

# --- 1. Build the standalone WASM kernel (Emscripten) --------------------
# emsdk location: $env:EMSDK, else the default per-user install.
$emsdk = if ($env:EMSDK) { $env:EMSDK } else { Join-Path $env:USERPROFILE 'emsdk' }
$emEnv = Join-Path $emsdk 'emsdk_env.ps1'
if (-not (Test-Path $emEnv)) {
    Write-Error "Emscripten not found at '$emsdk'. Install emsdk or set `$env:EMSDK (see native/README.md)."
    exit 1
}
Write-Host "Activating Emscripten ($emsdk)..."
# emsdk_env.ps1 shells out to python which writes to stderr; PowerShell 5.1
# would treat that as a terminating error under 'Stop'. Quiet it + relax EAP
# just for the sourcing.
$env:EMSDK_QUIET = '1'
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
. $emEnv *> $null
$ErrorActionPreference = $prevEAP

New-Item -ItemType Directory -Force (Join-Path $native 'web-wasm') | Out-Null
Push-Location $native
try {
    Write-Host "Building WASM kernel (emcc)..."
    $fns = "-sEXPORTED_FUNCTIONS=['_nb_load','_nb_bench','_nb_step_block','_nb_positions','_nb_tau_min','_nb_seed_demo','_nb_frame','_malloc','_free']"
    $rt = "-sEXPORTED_RUNTIME_METHODS=['ccall','cwrap','HEAPF64']"
    & emcc src/nbody_core.cpp src/nbody_wasm.cpp -O3 -std=c++17 `
        -sMODULARIZE=1 -sEXPORT_NAME=NBodyModule $fns $rt `
        -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web -o web-wasm/nbody.js
    if ($LASTEXITCODE -ne 0) { throw "emcc failed (exit $LASTEXITCODE)." }
}
finally { Pop-Location }

# --- 2. Export the Godot web build --------------------------------------
# godot.exe is a GUI-subsystem binary: PowerShell won't wait for it or see its
# exit code. Prefer the console build (*_console.exe) from the same directory.
$godot = (Get-Command godot -ErrorAction Stop).Source
$console = Get-ChildItem (Split-Path $godot) -Filter '*console.exe' | Select-Object -First 1
if ($console) { $godot = $console.FullName }

$webDir = Join-Path $root 'build\web'
New-Item -ItemType Directory -Force $webDir | Out-Null

Write-Host "Exporting web build..."
& $godot --headless --path $root --export-release 'Web' 'build/web/index.html'
if ($LASTEXITCODE -ne 0) {
    Write-Error "Web export failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

# --- 3. Bundle the WASM module next to index.html -----------------------
Copy-Item (Join-Path $native 'web-wasm\nbody.js') $webDir -Force
Copy-Item (Join-Path $native 'web-wasm\nbody.wasm') $webDir -Force

Write-Host "Web build (with native WASM kernel) written to $webDir"
