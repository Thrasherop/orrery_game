#ifndef ORRERY_NBODY_NATIVE_H
#define ORRERY_NBODY_NATIVE_H

// godot-cpp GDExtension wrapper (desktop/Android) around the pure NBodyCore.
// Prototype: measures the compiled kernel's speedup vs the GDScript integrator
// on identical state. Not yet wired into the live simulation.

#include "nbody_core.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace godot {

class NBodyNative : public RefCounted {
	GDCLASS(NBodyNative, RefCounted)

	NBodyCore core;

protected:
	static void _bind_methods();

public:
	void load(const PackedFloat64Array &ipx, const PackedFloat64Array &ipy, const PackedFloat64Array &ipz,
			const PackedFloat64Array &ivx, const PackedFloat64Array &ivy, const PackedFloat64Array &ivz,
			const PackedFloat64Array &im, double g_scale);

	void compute_accel(double g_scale) { core.compute_accel(g_scale); }
	void step_block(double H, double g_scale) { core.step_block(H, g_scale); }
	int64_t bench_blocks(int count, double H, double g_scale);
	PackedFloat64Array positions() const;
	double get_tau_min() const { return core.tau_min; }

	NBodyNative() {}
	~NBodyNative() {}
};

} // namespace godot

#endif // ORRERY_NBODY_NATIVE_H
