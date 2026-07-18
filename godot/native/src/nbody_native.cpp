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
	ClassDB::bind_method(D_METHOD("advance_frame", "px", "py", "pz", "vx", "vy", "vz",
			"m", "size", "bound_k", "fcx", "fcy", "fcz", "g_scale", "dt_days",
			"h_min", "h_max", "tau_frac", "budget", "reset_display"),
			&NBodyNative::advance_frame);
}

Dictionary NBodyNative::advance_frame(
		const PackedFloat64Array &ipx, const PackedFloat64Array &ipy, const PackedFloat64Array &ipz,
		const PackedFloat64Array &ivx, const PackedFloat64Array &ivy, const PackedFloat64Array &ivz,
		const PackedFloat64Array &im, const PackedFloat64Array &isize, const PackedFloat64Array &ibound_k,
		double fcx, double fcy, double fcz, double g_scale, double dt_days,
		double h_min, double h_max, double tau_frac, double budget, bool reset_display) {
	int n = ipx.size();
	if (core.n != n) { core.resize(n); reset_display = true; } // body set changed → reset display history
	for (int i = 0; i < n; i++) {
		core.px[i] = ipx[i]; core.py[i] = ipy[i]; core.pz[i] = ipz[i];
		core.vx[i] = ivx[i]; core.vy[i] = ivy[i]; core.vz[i] = ivz[i];
		core.m[i] = im[i]; core.size[i] = isize[i]; core.bound_k[i] = ibound_k[i];
	}
	core.frame_corr_x = fcx; core.frame_corr_y = fcy; core.frame_corr_z = fcz;
	core.compute_accel(g_scale);              // prime ax + tau to match the synced state
	if (reset_display) core.refresh_display(true);
	int status = core.advance(dt_days, g_scale, h_min, h_max, tau_frac, budget);

	PackedFloat64Array opx, opy, opz, ovx, ovy, ovz, odisp, otau;
	opx.resize(n); opy.resize(n); opz.resize(n);
	ovx.resize(n); ovy.resize(n); ovz.resize(n);
	odisp.resize((int64_t)n * 3); otau.resize(n);
	for (int i = 0; i < n; i++) {
		opx[i] = core.px[i]; opy[i] = core.py[i]; opz[i] = core.pz[i];
		ovx[i] = core.vx[i]; ovy[i] = core.vy[i]; ovz[i] = core.vz[i];
		odisp[i * 3 + 0] = core.dispx[i]; odisp[i * 3 + 1] = core.dispy[i]; odisp[i * 3 + 2] = core.dispz[i];
		otau[i] = core.tau_body[i];
	}
	Dictionary out;
	out["status"] = status;
	out["merge_i"] = core.merge_i;
	out["merge_j"] = core.merge_j;
	out["work"] = core.work;
	out["blocks"] = core.blocks;
	out["remaining_days"] = core.remaining_days;
	out["tau_min"] = core.tau_min;
	out["px"] = opx; out["py"] = opy; out["pz"] = opz;
	out["vx"] = ovx; out["vy"] = ovy; out["vz"] = ovz;
	out["disp"] = odisp; out["tau_body"] = otau;
	return out;
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
