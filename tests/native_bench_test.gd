extends Node
## Desktop prototype benchmark: compiled NBodyNative kernel vs the GDScript
## block integrator, on IDENTICAL seeded state.
##   <console-exe> --headless --path . res://tests/native_bench_test.tscn
## Measures (1) accuracy — the native kernel must reproduce the GDScript
## trajectory — and (2) the raw speedup on step_block, which is the ceiling a
## full native port could reach for the force+integration kernel. Decides
## whether the web-WASM + Android-NDK build effort is worth it.

const EPOCH_MS := 1767225600000.0
const H := 0.1
const ACC_BLOCKS := 200
const BENCH_BLOCKS := 20000


func _ready() -> void:
	if not ClassDB.class_exists("NBodyNative"):
		printerr("FAIL  NBodyNative not registered — the GDExtension didn't load.")
		printerr("      (build native/, confirm bin/*.dll + bin/orrery_native.gdextension)")
		get_tree().quit(1)
		return
	print("[native_bench] NBodyNative loaded OK")
	_run("all moons", true)
	_run("planets only", false)
	_test_advance_frame()
	get_tree().quit(0)


## Validate the full-frame native advance() against a GDScript block-loop
## replica on identical seeded all-moons state: physics must stay bit-exact
## (collision disabled via size=0 so we isolate the integration).
func _test_advance_frame() -> void:
	print("\n=== advance_frame vs GDScript block loop (all moons) ===")
	var sim := Simulation.new()
	add_child(sim)
	sim.sim_ms = EPOCH_MS
	if not sim.moons_simulated:
		sim.set_moons_simulated(true)
	sim.tick(0.0)
	sim.add_custom_body({ name = "Trigger", mass_e = 0.0001, dist_au = 40.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 4.7, dir_deg = 0.0 })
	var nb = sim.nb
	var n := nb.count()
	var g: float = sim.g_scale
	var fc: Vector3 = nb.frame_corr
	var snap := _snapshot(nb)
	var zeros := PackedFloat64Array(); zeros.resize(n)   # size + bound_k = 0 → no merges

	var dt_days := 3.0
	var H_MIN := 1e-4
	var H_MAX := 0.1
	var TAU_FRAC := 0.4
	var BIG := 1.0e9

	# native: one advance_frame call over the whole dt
	var nat = ClassDB.instantiate("NBodyNative")
	var r: Dictionary = nat.advance_frame(snap.px, snap.py, snap.pz, snap.vx, snap.vy, snap.vz,
		snap.m, zeros, zeros, fc.x, fc.y, fc.z, g, dt_days, H_MIN, H_MAX, TAU_FRAC, BIG, true)

	# gdscript reference: same schedule, on the same snapshot
	nb.px = snap.px.duplicate(); nb.py = snap.py.duplicate(); nb.pz = snap.pz.duplicate()
	nb.vx = snap.vx.duplicate(); nb.vy = snap.vy.duplicate(); nb.vz = snap.vz.duplicate()
	nb.m = snap.m.duplicate()
	nb.compute_accel(g)
	nb.refresh_display(true)
	var remaining := dt_days
	var work := 0.0
	while remaining > 1e-9 and work < BIG:
		var H := minf(clampf(nb.tau_min * TAU_FRAC, H_MIN, H_MAX), remaining)
		nb.step_block(H, g)
		work += 1.0 + 2.0 * float(nb.last_fast_evals) / maxf(n * n, 1.0)
		nb.refresh_display(false)
		remaining -= H

	var rpx: PackedFloat64Array = r.px
	var rvx: PackedFloat64Array = r.vx
	var max_dp := 0.0
	var max_dv := 0.0
	for i in n:
		max_dp = maxf(max_dp, absf(rpx[i] - nb.px[i]))
		max_dv = maxf(max_dv, absf(rvx[i] - nb.vx[i]))
	print("  status=%d blocks=%d  max |Δpx|=%s max |Δvx|=%s %s" % [
		int(r.status), int(r.blocks), _sci(max_dp), _sci(max_dv),
		"(bit-exact)" if max_dp == 0.0 and max_dv == 0.0 else "(MISMATCH)"])


func _snapshot(nb) -> Dictionary:
	return {
		px = nb.px.duplicate(), py = nb.py.duplicate(), pz = nb.pz.duplicate(),
		vx = nb.vx.duplicate(), vy = nb.vy.duplicate(), vz = nb.vz.duplicate(),
		m = nb.m.duplicate(),
	}


func _run(label: String, moons_on: bool) -> void:
	print("\n=== %s (n varies) ===" % label)
	var sim := Simulation.new()
	add_child(sim)
	sim.sim_ms = EPOCH_MS
	if sim.moons_simulated != moons_on:
		sim.set_moons_simulated(moons_on)
	sim.tick(0.0)
	# enter physics without locking: a tiny far body
	sim.add_custom_body({
		name = "Trigger", mass_e = 0.0001, dist_au = 40.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 4.7, dir_deg = 0.0,
	})
	var nb = sim.nb
	var n := nb.count()
	var g: float = sim.g_scale
	var snap := _snapshot(nb)

	# ---- accuracy: native must track GDScript over ACC_BLOCKS ----
	var nat = ClassDB.instantiate("NBodyNative")
	nat.load(snap.px, snap.py, snap.pz, snap.vx, snap.vy, snap.vz, snap.m, g)
	for k in ACC_BLOCKS:
		nat.step_block(H, g)
	for k in ACC_BLOCKS:
		nb.step_block(H, g)
	var np: PackedFloat64Array = nat.positions()
	var max_div := 0.0
	for i in n:
		var gx: float = nb.px[i] - nb.px[0]
		var gy: float = nb.py[i] - nb.py[0]
		var gz: float = nb.pz[i] - nb.pz[0]
		var dx: float = np[i * 3 + 0] - gx
		var dy: float = np[i * 3 + 1] - gy
		var dz: float = np[i * 3 + 2] - gz
		var d := sqrt(dx * dx + dy * dy + dz * dz)
		if d > max_div:
			max_div = d
	print("  accuracy over %d blocks: max |Δpos| = %s AU %s" % [
		ACC_BLOCKS, _sci(max_div), "(kernels agree)" if max_div < 1e-4 else "(DIVERGED)"])

	# ---- timing: fresh identical state, BENCH_BLOCKS each ----
	# GDScript
	nb.px = snap.px.duplicate(); nb.py = snap.py.duplicate(); nb.pz = snap.pz.duplicate()
	nb.vx = snap.vx.duplicate(); nb.vy = snap.vy.duplicate(); nb.vz = snap.vz.duplicate()
	nb.m = snap.m.duplicate()
	nb.compute_accel(g)
	nat.load(snap.px, snap.py, snap.pz, snap.vx, snap.vy, snap.vz, snap.m, g)
	# warm-up
	for k in 200:
		nb.step_block(H, g)
	var gd0 := Time.get_ticks_usec()
	for k in BENCH_BLOCKS:
		nb.step_block(H, g)
	var gd_us := Time.get_ticks_usec() - gd0
	var nat_us: int = nat.bench_blocks(BENCH_BLOCKS, H, g)

	var gd_per := float(gd_us) / BENCH_BLOCKS
	var nat_per := float(nat_us) / BENCH_BLOCKS
	print("  GDScript : %d blocks in %.1f ms  (%.2f us/block)" % [BENCH_BLOCKS, gd_us / 1000.0, gd_per])
	print("  native   : %d blocks in %.1f ms  (%.2f us/block)" % [BENCH_BLOCKS, nat_us / 1000.0, nat_per])
	print("  >>> speedup: %.1fx" % (gd_per / maxf(nat_per, 0.001)))


func _sci(x: float) -> String:
	if x == 0.0:
		return "0"
	var neg := x < 0.0
	var ax := absf(x)
	var e := floori(log(ax) / log(10.0))
	return "%s%.2fe%d" % ["-" if neg else "", ax / pow(10.0, e), e]
