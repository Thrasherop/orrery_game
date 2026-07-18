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
	// display compression (Units.gd)
	static constexpr double DIST_K = 26.0;
	static constexpr double DIST_P = 0.62;
	static constexpr double DIST_R0 = 0.02;
	// advance() result status
	static constexpr int DONE = 0;
	static constexpr int BUDGET = 1;
	static constexpr int MERGE = 2;

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

	// collision + display state (owned by GDScript, synced in each frame)
	std::vector<double> size;      // display radius per body
	std::vector<double> bound_k;   // moon display amplification (0 if not a bound moon)
	std::vector<double> dispx, dispy, dispz;       // display positions
	std::vector<double> pdispx, pdispy, pdispz;    // previous-block display positions
	double frame_corr_x = 0.0, frame_corr_y = 0.0, frame_corr_z = 0.0;
	double bary_x = 0.0, bary_y = 0.0, bary_z = 0.0;

	// advance() outputs
	int merge_i = -1, merge_j = -1;
	double work = 0.0;
	double remaining_days = 0.0;
	int blocks = 0;

	void resize(int n_);
	void compute_accel(double g_scale);
	void accel_on(int fi, double t, double H, double G);
	void step_block(double H, double g_scale);

	// display + collision (ports of nbody.gd / units.gd)
	static double dist_scale(double r);
	void to_display(double vx_, double vy_, double vz_, double &ox, double &oy, double &oz);
	void refresh_display(bool reset_prev);
	double real_distance(int i, int j) const;
	double swept_distance(int i, int j) const;
	double enc_distance(int i, int j) const;

	// Run a whole frame: blocks of subcycled leapfrog + display refresh +
	// collision detection, until dt_days is consumed (DONE), the work budget
	// is hit (BUDGET), or a merge is detected (MERGE; merge_i/merge_j set and
	// the caller resolves it in game logic, re-syncs, and calls again for
	// remaining_days). Requires ax/tau primed (call compute_accel after a sync).
	int advance(double dt_days, double g_scale, double h_min, double h_max,
			double tau_frac, double budget);
};

#endif // ORRERY_NBODY_CORE_H
