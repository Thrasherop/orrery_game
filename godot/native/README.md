# Native N-body kernel (prototype)

Compiled C++ mirror of the hot N-body kernel from [`../src/core/nbody.gd`](../src/core/nbody.gd),
built to measure — and eventually ship — a large speedup over the GDScript
block integrator. **Feasibility is proven; this is not yet wired into the live
simulation.**

Measured (2026-07): **~67× on desktop** (bit-exact vs GDScript), **~84× in a
web export** running in Chrome (GDScript is slowest in the browser, so the win
is biggest exactly where it's needed).

## Layout

- `src/nbody_core.{h,cpp}` — the pure C++ kernel (no Godot deps): `compute_accel`
  + `step_block` (block time-stepping with power-of-2 subcycling). **Shared by
  both platform wrappers below.**
- `src/nbody_native.{h,cpp}`, `src/register_types.*` — godot-cpp GDExtension
  wrapper for **desktop / Android**.
- `src/nbody_wasm.cpp` — `extern "C"` wrapper compiled to a **standalone WASM
  module** for **web**, driven from GDScript via `JavaScriptBridge` (no
  GDExtension, no custom engine templates, no COOP/COEP — see below).

## Build — desktop GDExtension (CMake + Ninja)

Use CMake+Ninja, **not SCons** (SCons deadlocks on Windows at the `ar` archive step).

```sh
git clone --depth 1 --branch 4.4 https://github.com/godotengine/godot-cpp.git
cmake -S . -B build-cmake -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++
cmake --build build-cmake -j
```

Produces `../bin/liborrery_native.dll` (loaded via `../bin/orrery_native.gdextension`).
The MinGW runtime is statically linked in (`-static`) so the dll is self-contained.

## Build — Android GDExtension (NDK)

`scripts/build-android.ps1` does this + exports the APK. It needs the Android
NDK (finds it via `$env:ANDROID_NDK_HOME` or the SDK's `ndk/` dir) and the
godot-cpp checkout. Manual arm64 build:

```sh
NDK=/path/to/android-ndk
cmake -S . -B build-android-arm64-v8a -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DORRERY_OUTPUT_NAME=orrery_native.android.arm64-v8a
cmake --build build-android-arm64-v8a -j
```

Produces `../bin/liborrery_native.android.arm64-v8a.so` (static libc++, deps
only libc/libm/libdl). The `android.*.arm64` entries in
`../bin/orrery_native.gdextension` point at it; Godot packs it into the APK's
`lib/arm64-v8a/`. For more ABIs, repeat with `-DANDROID_ABI=armeabi-v7a`
(arch tag `arm32`) / `x86_64` and add matching `.gdextension` entries.

## Build — web WASM (Emscripten)

Any recent emsdk works (the module is independent of Godot's own runtime).

```sh
source /path/to/emsdk/emsdk_env.sh
emcc src/nbody_core.cpp src/nbody_wasm.cpp -O3 -std=c++17 \
  -sMODULARIZE=1 -sEXPORT_NAME=NBodyModule \
  -sEXPORTED_FUNCTIONS='["_nb_load","_nb_bench","_nb_step_block","_nb_positions","_nb_tau_min","_nb_seed_demo","_malloc","_free"]' \
  -sEXPORTED_RUNTIME_METHODS='["ccall","cwrap","HEAPF64"]' \
  -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web -o web-wasm/nbody.js
```

Copy `web-wasm/nbody.js` + `nbody.wasm` next to the exported `build/web/index.html`;
GDScript loads them via `JavaScriptBridge`. A `.gdextension` with no `web`
library entry must be moved aside during a web export (web uses the WASM, not
the extension), then restored + rescanned (`godot --headless --editor --quit`).

## Benchmarks

- Desktop: `godot --headless --path .. res://tests/native_bench_test.tscn`
- Web PoC: `tests/web_native_poc.{gd,tscn}` (set as temp main scene, export web,
  serve, open in Chrome). `web-wasm/test.html` is the standalone (no-Godot) page.
