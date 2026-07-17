#ifndef ORRERY_NBODY_CORE_H
#define ORRERY_NBODY_CORE_H

// Pure C++ N-body kernel — NO Godot dependencies. Shared by both platform
// wrappers: the godot-cpp GDExtension (desktop/Android) and the standalone
// Emscripten WASM module (web, driven via JavaScriptBridge). Mirrors the hot
// path of src/core/nbody.gd operation-for-operation (bit-identical results).

#include <vector>

struct NBodyCore {
	static constexpr double GM_SUN = 2.9591220828559e-4; // Units.GM_SUN
	static constexpr double EPS2 = 1e-8;
	static constexpr double MASS_COMPARABLE = 0.01;
	static constexpr double SAFETY = 20.0;
	static constexpr int K_MAX = 8;
	static constexpr double INF_D = 1e300;

	int n = 0;
	std::vector<double> px, py, pz;
	std::vector<double> vx, vy, vz;
	std::vector<double> ax, ay, az;
	std::vector<double> m;
	std::vector<double> tau_body;
	std::vector<int> k_sub;
	std::vector<double> enc_min_r2;
	double tau_min = INF_D;
	bool had_fast = false;
	long long last_fast_evals = 0;
	double _f_ax = 0.0, _f_ay = 0.0, _f_az = 0.0;

	void resize(int n_);
	void compute_accel(double g_scale);
	void accel_on(int fi, double t, double H, double G);
	void step_block(double H, double g_scale);
};

#endif // ORRERY_NBODY_CORE_H
