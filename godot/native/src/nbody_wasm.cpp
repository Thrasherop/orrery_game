// Standalone Emscripten WASM wrapper around NBodyCore for the WEB target.
// Runs as an independent module in the browser page (NOT inside Godot's own
// wasm runtime), driven from GDScript through JavaScriptBridge. No godot-cpp,
// no dlink templates, no SharedArrayBuffer — a plain single-threaded module.

#include "nbody_core.h"
#include <emscripten.h>
#include <cmath>

static NBodyCore g_core;

extern "C" {

// Load n bodies from an interleaved buffer: 7 doubles per body
// [px,py,pz,vx,vy,vz,m]. Primes acceleration + tau.
EMSCRIPTEN_KEEPALIVE
void nb_load(int n, double *buf, double g_scale) {
	g_core.resize(n);
	for (int i = 0; i < n; i++) {
		double *b = buf + (size_t)i * 7;
		g_core.px[i] = b[0]; g_core.py[i] = b[1]; g_core.pz[i] = b[2];
		g_core.vx[i] = b[3]; g_core.vy[i] = b[4]; g_core.vz[i] = b[5];
		g_core.m[i] = b[6];
	}
	g_core.compute_accel(g_scale);
}

// Run `count` blocks of size H; return a checksum (keeps the loop live).
EMSCRIPTEN_KEEPALIVE
double nb_bench(int count, double H, double g_scale) {
	for (int b = 0; b < count; b++) g_core.step_block(H, g_scale);
	double s = 0.0;
	for (int i = 0; i < g_core.n; i++) s += g_core.px[i] + g_core.py[i] + g_core.pz[i];
	return s;
}

// One block (real per-frame use will call this in a loop).
EMSCRIPTEN_KEEPALIVE
void nb_step_block(double H, double g_scale) { g_core.step_block(H, g_scale); }

// Interleaved (x,y,z) heliocentric positions into out (length 3n).
EMSCRIPTEN_KEEPALIVE
void nb_positions(double *out) {
	if (g_core.n == 0) return;
	double sx = g_core.px[0], sy = g_core.py[0], sz = g_core.pz[0];
	for (int i = 0; i < g_core.n; i++) {
		out[i * 3 + 0] = g_core.px[i] - sx;
		out[i * 3 + 1] = g_core.py[i] - sy;
		out[i * 3 + 2] = g_core.pz[i] - sz;
	}
}

EMSCRIPTEN_KEEPALIVE
double nb_tau_min() { return g_core.tau_min; }

// Synthetic representative system (sun + planets + a few tight fast bodies to
// force subcycling) — lets the browser prove the pipeline before real state
// marshalling.
EMSCRIPTEN_KEEPALIVE
void nb_seed_demo(int n) {
	g_core.resize(n);
	g_core.px[0] = g_core.py[0] = g_core.pz[0] = 0.0;
	g_core.vx[0] = g_core.vy[0] = g_core.vz[0] = 0.0;
	g_core.m[0] = 1.0;
	for (int i = 1; i < n; i++) {
		double a = 0.4 + i * 0.35;
		double v = std::sqrt(NBodyCore::GM_SUN / a);
		g_core.px[i] = a; g_core.py[i] = 0.0; g_core.pz[i] = 0.0;
		g_core.vx[i] = 0.0; g_core.vy[i] = v; g_core.vz[i] = 0.0;
		g_core.m[i] = (i % 4 == 0) ? 1e-3 : 1e-7;
	}
	// two tight moons hugging a heavy body → short tau → subcycling like Io
	if (n > 6) {
		int host = 4;
		for (int k = 0; k < 2 && host + 1 + k < n; k++) {
			int mi = host + 1 + k;
			double da = 0.002 + k * 0.001;
			g_core.px[mi] = g_core.px[host] + da;
			g_core.py[mi] = 0.0; g_core.pz[mi] = 0.0;
			double vmoon = std::sqrt(NBodyCore::GM_SUN * g_core.m[host] / da);
			g_core.vx[mi] = 0.0; g_core.vy[mi] = g_core.vy[host] + vmoon; g_core.vz[mi] = 0.0;
			g_core.m[mi] = 1e-8;
		}
	}
	g_core.compute_accel(1.0);
}

} // extern "C"
