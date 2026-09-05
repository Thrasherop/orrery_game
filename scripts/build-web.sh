#!/usr/bin/env bash
# Linux/CI counterpart of build-web.ps1: exports a release web build to
# build/web/, INCLUDING the native WASM physics kernel (nbody.js + nbody.wasm)
# that the game loads at runtime via JavaScriptBridge.
#
# Split into two phases so the Dockerfile can run each in its own stage
# (Emscripten and Godot are big, unrelated toolchains — no image has both):
#
#   build-web.sh --wasm-only     needs emcc     -> native/web-wasm/nbody.{js,wasm}
#   build-web.sh --export-only   needs godot    -> build/web/ (+ copies the wasm in)
#   build-web.sh                 needs both     -> the whole thing, for local dev
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
native="$root/native"
web_dir="$root/build/web"

do_wasm=1
do_export=1
case "${1:-}" in
    --wasm-only)   do_export=0 ;;
    --export-only) do_wasm=0 ;;
    "")            ;;
    *) echo "usage: $0 [--wasm-only|--export-only]" >&2; exit 2 ;;
esac

# --- 1. Build the standalone WASM kernel (Emscripten) --------------------
# Note this compiles only nbody_core.cpp + nbody_wasm.cpp: the web kernel is
# plain C++ with no Godot dependency, so godot-cpp is NOT needed here.
if [ "$do_wasm" = 1 ]; then
    command -v emcc >/dev/null || { echo "emcc not found. Source emsdk_env.sh first (see native/README.md)." >&2; exit 1; }
    mkdir -p "$native/web-wasm"
    echo "Building WASM kernel (emcc)..."
    (
        cd "$native"
        emcc src/nbody_core.cpp src/nbody_wasm.cpp -O3 -std=c++17 \
            -sMODULARIZE=1 -sEXPORT_NAME=NBodyModule \
            -sEXPORTED_FUNCTIONS="['_nb_load','_nb_bench','_nb_step_block','_nb_positions','_nb_tau_min','_nb_seed_demo','_nb_frame','_malloc','_free']" \
            -sEXPORTED_RUNTIME_METHODS="['ccall','cwrap','HEAPF64']" \
            -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web \
            -o web-wasm/nbody.js
    )
fi

[ "$do_export" = 1 ] || { echo "WASM kernel written to $native/web-wasm"; exit 0; }

# --- 2. Export the Godot web build --------------------------------------
command -v godot >/dev/null || { echo "godot not found on PATH." >&2; exit 1; }
mkdir -p "$web_dir"

# bin/orrery_native.gdextension declares linux/windows/android libraries that
# are gitignored build artifacts, so on a clean checkout the loader finds
# nothing and aborts before the export runs. Web doesn't use the extension at
# all (it uses the WASM module above), so move the manifest aside for the
# duration of the export and always put it back. See native/README.md.
gdext="$native/../bin/orrery_native.gdextension"
if [ -f "$gdext" ]; then
    mv "$gdext" "$gdext.disabled"
    trap 'mv "$gdext.disabled" "$gdext" 2>/dev/null || true' EXIT
fi

# A fresh checkout has no .godot/ import cache, and --export-release will not
# create one: without this step the export ships no assets. Run it first.
echo "Importing resources..."
godot --headless --path "$root" --import

echo "Exporting web build..."
godot --headless --path "$root" --export-release 'Web' 'build/web/index.html'

# --- 3. Bundle the WASM module next to index.html -----------------------
cp "$native/web-wasm/nbody.js" "$native/web-wasm/nbody.wasm" "$web_dir/"

echo "Web build (with native WASM kernel) written to $web_dir"
