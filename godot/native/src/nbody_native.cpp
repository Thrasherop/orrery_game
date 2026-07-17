#include "nbody_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <chrono>

using namespace godot;

void NBodyNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load", "px", "py", "pz", "vx", "vy", "vz", "m", "g_scale"), &NBodyNative::load);
	ClassDB::bind_method(D_METHOD("compute_accel", "g_scale"), &NBodyNative::compute_accel);
	ClassDB::bind_method(D_METHOD("step_block", "H", "g_scale"), &NBodyNative::step_block);
	ClassDB::bind_method(D_METHOD("bench_blocks", "count", "H", "g_scale"), &NBodyNative::bench_blocks);
	ClassDB::bind_method(D_METHOD("positions"), &NBodyNative::positions);
	ClassDB::bind_method(D_METHOD("get_tau_min"), &NBodyNative::get_tau_min);
}

void NBodyNative::load(const PackedFloat64Array &ipx, const PackedFloat64Array &ipy, const PackedFloat64Array &ipz,
		const PackedFloat64Array &ivx, const PackedFloat64Array &ivy, const PackedFloat64Array &ivz,
		const PackedFloat64Array &im, double g_scale) {
	core.resize(ipx.size());
	for (int i = 0; i < core.n; i++) {
		core.px[i] = ipx[i]; core.py[i] = ipy[i]; core.pz[i] = ipz[i];
		core.vx[i] = ivx[i]; core.vy[i] = ivy[i]; core.vz[i] = ivz[i];
		core.m[i] = im[i];
	}
	core.compute_accel(g_scale);
}

int64_t NBodyNative::bench_blocks(int count, double H, double g_scale) {
	auto t0 = std::chrono::high_resolution_clock::now();
	for (int b = 0; b < count; b++) core.step_block(H, g_scale);
	auto t1 = std::chrono::high_resolution_clock::now();
	return std::chrono::duration_cast<std::chrono::microseconds>(t1 - t0).count();
}

PackedFloat64Array NBodyNative::positions() const {
	PackedFloat64Array out;
	out.resize((int64_t)core.n * 3);
	const double sx = core.n > 0 ? core.px[0] : 0.0;
	const double sy = core.n > 0 ? core.py[0] : 0.0;
	const double sz = core.n > 0 ? core.pz[0] : 0.0;
	for (int i = 0; i < core.n; i++) {
		out[i * 3 + 0] = core.px[i] - sx;
		out[i * 3 + 1] = core.py[i] - sy;
		out[i * 3 + 2] = core.pz[i] - sz;
	}
	return out;
}
