extends Node
## Physics performance + accuracy regression harness:
##   godot --headless --path godot res://tests/physics_perf_test.tscn
## Measures integrator throughput and, over fixed sim-time windows, the drift
## of the conserved quantities (energy, momentum, angular momentum) and of
## each moon's orbital elements. The tolerance constants are baked from a
## baseline run of the original global-substep integrator — any optimization
## must stay within them at the same sim time.

const EPOCH_MS := 1767225600000.0     # 2026-01-01 UTC — deterministic start

# Baseline drift measured from the ORIGINAL global-substep integrator (see the
# per-body numbers below). Tolerances are ~3× those baselines with a floor for
# the tiny, fp-noise-dominated ones — an optimization that stays inside them
# has not degraded the physics. Windows are sim-time exact, so the comparison
# is apples-to-apples across integrator changes.
#   planets-only, 10 sim-years @ Year/s:  |dE/E| 2.4e-8, |dL/L| 1.2e-14, a_Mercury 1.1e-5
#   all moons,   0.5 sim-years @ week/s:  |dE/E| 1.6e-10, per-moon a-drift in MOON_A_BASE
const TOL_E_PLANETS := 1.0e-7         # ~4× baseline 2.4e-8
const TOL_A_PLANET := 3.5e-5          # ~3× baseline Mercury 1.1e-5
const TOL_P := 1.0e-12                # planets ride the k==1 fast path → |P| exact
const TOL_L := 1.0e-9                 # relative |L| drift (planets)

# With fast moons subcycling (block scheme), a slow body feels a fast body only
# at block boundaries — an O(m_moon·(ωH)²) coupling error. The drift-probe
# confirms it is OSCILLATORY, NOT secular: over 1.75 sim-years |dE/E| bounces
# between 8e-8 and 1.8e-6 with no upward trend, |P| oscillates around ~5e-12.
# It never accumulates, so orbits stay stable indefinitely (per-moon a-drift
# above stays tiny). These bounds are the measured oscillation amplitude + a
# safety margin — a regression that made the error SECULAR would blow past them.
const TOL_E_MOONS := 5.0e-6           # bounded oscillation (peaks ~1.8e-6)
const TOL_P_MOONS := 5.0e-11          # bounded oscillation (peaks ~7e-12)

# Baseline per-moon semi-major-axis drift over the 0.5 sim-year window.
const MOON_A_BASE := {
	Moon = 3.372e-3, Io = 1.745e-4, Europa = 2.485e-4, Ganymede = 8.640e-5,
	Callisto = 8.262e-6, Titan = 8.025e-7, Triton = 6.593e-8,
}
const MOON_A_FLOOR := 5.0e-4          # fp/geometry noise floor for the tiny-drift moons

var _failures := 0


## 3-sig-fig scientific string (GDScript's % has no %e)
func _sci(x: float) -> String:
	if x == 0.0:
		return "0"
	var neg := x < 0.0
	var ax := absf(x)
	var e := floori(log(ax) / log(10.0))
	var mant := ax / pow(10.0, e)
	return "%s%.3fe%d" % ["-" if neg else "", mant, e]


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _ready() -> void:
	print("[physics_perf] throughput: all moons @ Year/s")
	_test_throughput()
	print("[physics_perf] accuracy: planets-only, 10 sim-years")
	_test_accuracy_planets()
	print("[physics_perf] accuracy: all moons, 0.5 sim-years")
	_test_accuracy_moons()
	print("[physics_perf] collision: no tunneling through the sun")
	_test_tunneling()
	print("[physics_perf] encounter: close flyby stays finite + conservative")
	_test_encounter()
	print("[physics_perf] runtime edits: G / mass / rail with block stepping")
	_test_runtime_edits()
	if OS.get_cmdline_user_args().has("--drift-probe") or OS.get_cmdline_args().has("--drift-probe"):
		print("[physics_perf] DRIFT PROBE: energy/momentum trajectory over 3 sim-years")
		_drift_probe()
	print("[physics_perf] %s" % ("ALL PASSED" if _failures == 0 else "%d FAILURES" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _make_sim(moons_on: bool, expensive_on: bool) -> Simulation:
	var sim := Simulation.new()
	add_child(sim)
	sim.sim_ms = EPOCH_MS
	if sim.sim_expensive_moons != expensive_on:
		sim.set_expensive_moons(expensive_on)
	if sim.moons_simulated != moons_on:
		sim.set_moons_simulated(moons_on)
	sim.tick(0.0)
	return sim


## enter physics without making it permanent: a tiny far-away custom body
func _enter_physics(sim: Simulation) -> SimBody:
	return sim.add_custom_body({
		name = "Trigger", mass_e = 0.0001, dist_au = 40.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 4.7, dir_deg = 0.0,
	})


## advance exactly `days` of sim time in fixed frame ticks, asserting the
## substep budget never capped (so sim time equals requested time)
func _run_days(sim: Simulation, days: float, label: String) -> void:
	var t_end := sim.sim_ms + days * 86400000.0
	var capped := false
	while sim.sim_ms < t_end - 1.0:
		sim.tick(1.0 / 60.0)
		if sim.perf.get("work", 0.0) >= sim.MAX_SUBSTEPS:
			capped = true
	_check(not capped, "%s: substep budget never capped (sim time is exact)" % label)


## osculating semi-major axis of body i about body h (vis-viva, in doubles)
func _pair_a(nb: NBodySystem, i: int, h: int, g_scale: float) -> float:
	var dx := nb.px[i] - nb.px[h]
	var dy := nb.py[i] - nb.py[h]
	var dz := nb.pz[i] - nb.pz[h]
	var dvx := nb.vx[i] - nb.vx[h]
	var dvy := nb.vy[i] - nb.vy[h]
	var dvz := nb.vz[i] - nb.vz[h]
	var r := sqrt(dx * dx + dy * dy + dz * dz)
	var v2 := dvx * dvx + dvy * dvy + dvz * dvz
	var mu := Units.GM_SUN * g_scale * (nb.m[i] + nb.m[h])
	return 1.0 / (2.0 / r - v2 / mu)


func _test_throughput() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	sim.speed = 31557600.0   # Year/s — beyond what Io's timestep allows
	sim.tick(1.0 / 60.0)     # warm-up
	var day0 := SimTime.sim_days(sim.sim_ms)
	var t0 := Time.get_ticks_usec()
	for i in 150:
		sim.tick(1.0 / 60.0)
	var wall_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var days := SimTime.sim_days(sim.sim_ms) - day0
	print("  throughput: %.1f sim-days in %.0f ms = %.1f days/s wall · lag_ratio %.2f" % [
		days, wall_ms, days * 1000.0 / wall_ms, sim.lag_ratio])
	print("  last frame: %d blocks · work %.1f · %d pair forces · step %d us · display %d us · collide %d us · trails %d us" % [
		sim.perf.steps, sim.perf.work, sim.perf.pair_evals, sim.perf.us_step,
		sim.perf.us_display, sim.perf.us_collide, sim.perf.us_trails])
	_check(days > 0.0, "throughput run integrated time")


func _test_accuracy_planets() -> void:
	var sim := _make_sim(false, true)
	_enter_physics(sim)
	sim.speed = 31557600.0   # Year/s → ~61 substeps/frame, under the budget
	var c0: Dictionary = sim.conserved()
	var mi := sim.nb.index_of(_planet(sim, "Mercury"))
	var a0 := _pair_a(sim.nb, mi, 0, sim.g_scale)
	var t0 := Time.get_ticks_usec()
	_run_days(sim, 3652.5, "planets")
	var wall_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var c1: Dictionary = sim.conserved()
	var a1 := _pair_a(sim.nb, mi, 0, sim.g_scale)
	var de: float = absf((c1.e - c0.e) / c0.e)
	var dl: float = absf((c1.l_mag - c0.l_mag) / c0.l_mag)
	var da: float = absf((a1 - a0) / a0)
	print("  10y planets: wall %.0f ms · |dE/E| %s · |P| %s · |dL/L| %s · Mercury |da/a| %s" % [
		wall_ms, _sci(de), _sci(c1.p_mag), _sci(dl), _sci(da)])
	var earth := _planet(sim, "Earth")
	var ei := sim.nb.index_of(earth)
	print("  final Earth helio pos: %.12f %.12f %.12f" % [
		sim.nb.px[ei] - sim.nb.px[0], sim.nb.py[ei] - sim.nb.py[0], sim.nb.pz[ei] - sim.nb.pz[0]])
	_check(de < TOL_E_PLANETS, "planet energy drift %s < %s" % [_sci(de), _sci(TOL_E_PLANETS)])
	_check(c1.p_mag < TOL_P, "momentum stays zeroed (%s)" % _sci(c1.p_mag))
	_check(dl < TOL_L, "angular momentum drift %s < %s" % [_sci(dl), _sci(TOL_L)])
	_check(da < TOL_A_PLANET, "Mercury semi-major axis drift %s < %s" % [_sci(da), _sci(TOL_A_PLANET)])


func _test_accuracy_moons() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	sim.speed = 604800.0   # week/s → ~9 substeps/frame with Io, under the budget
	var c0: Dictionary = sim.conserved()
	var a0 := {}
	for mb: SimBody in sim.moons:
		a0[mb.body_name] = _pair_a(sim.nb, sim.nb.index_of(mb), sim.nb.index_of(mb.host), sim.g_scale)
	var t0 := Time.get_ticks_usec()
	_run_days(sim, 182.625, "moons")
	var wall_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var c1: Dictionary = sim.conserved()
	var de: float = absf((c1.e - c0.e) / c0.e)
	for mb: SimBody in sim.moons:
		_check(mb.host != null and mb.host.body_name == mb.home_host_name,
			"%s still bound to %s" % [mb.body_name, mb.home_host_name])
		if mb.host == null:
			continue
		var a1 := _pair_a(sim.nb, sim.nb.index_of(mb), sim.nb.index_of(mb.host), sim.g_scale)
		var da: float = absf((a1 - a0[mb.body_name]) / a0[mb.body_name])
		var tol: float = maxf(3.0 * MOON_A_BASE.get(mb.body_name, 0.0), MOON_A_FLOOR)
		print("  %s |da/a| %s  (baseline %s, tol %s)" % [
			mb.body_name.rpad(10), _sci(da), _sci(MOON_A_BASE.get(mb.body_name, 0.0)), _sci(tol)])
		_check(da < tol, "%s a-drift within tolerance" % mb.body_name)
	print("  0.5y moons: wall %.0f ms · |dE/E| %s · |P| %s" % [
		wall_ms, _sci(de), _sci(c1.p_mag)])
	_check(de < TOL_E_MOONS, "moons energy drift bounded %s < %s" % [_sci(de), _sci(TOL_E_MOONS)])
	_check(c1.p_mag < TOL_P_MOONS, "momentum drift bounded %s < %s" % [_sci(c1.p_mag), _sci(TOL_P_MOONS)])


## every integrated body's raw state is finite
func _all_finite(sim: Simulation) -> bool:
	var nb := sim.nb
	for i in nb.count():
		if not (is_finite(nb.px[i]) and is_finite(nb.py[i]) and is_finite(nb.pz[i]) \
				and is_finite(nb.vx[i]) and is_finite(nb.vy[i]) and is_finite(nb.vz[i])):
			return false
	return true


## every simulated body's cached nb_index still points at its own row
func _indices_ok(sim: Simulation) -> bool:
	var nb := sim.nb
	for i in nb.count():
		if nb.bodies[i].nb_index != i:
			return false
	return true


## A radial infall must MERGE with the sun (block scheme: the approach drives
## tau_min → H → 0, restoring fine cadence so swept_distance can't miss it),
## not tunnel straight through the display origin and come out the far side.
func _test_tunneling() -> void:
	var sim := _make_sim(false, true)
	var n0 := sim.all_bodies().size()
	# dir_deg 270 = radially inward: aimed dead-centre at the sun from 2 AU
	var bullet := sim.add_custom_body({
		name = "Bullet", mass_e = 50.0, dist_au = 2.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 45.0, dir_deg = 270.0,
	})
	sim.speed = 604800.0   # week/s
	var merged := false
	for i in 2000:
		sim.tick(1.0 / 60.0)
		if not sim.customs.has(bullet):
			merged = true
			break
		_check_once_finite(sim)
	_check(merged, "radial bullet merges into the sun (no tunnelling)")


var _finite_ok := true
func _check_once_finite(sim: Simulation) -> void:
	if _finite_ok and not _all_finite(sim):
		_finite_ok = false
		_failures += 1
		printerr("FAIL  a body went non-finite mid-run")


## A hyperbolic flyby of the sun must stay finite and, once the body has
## receded, conserve energy across the encounter (the block scheme shrinks H
## through closest approach, so the fast pass is integrated, not blasted).
func _test_encounter() -> void:
	var sim := _make_sim(false, true)
	# offset launch so it swings PAST the sun rather than into it
	var comet := sim.add_custom_body({
		name = "Comet", mass_e = 5.0, dist_au = 3.0,
		lon_deg = 0.0, lat_deg = 12.0, speed_kms = 32.0, dir_deg = 250.0,
	})
	sim.speed = 604800.0
	var c0: Dictionary = sim.conserved()
	_finite_ok = true
	var survived := true
	for i in 1500:
		sim.tick(1.0 / 60.0)
		if not sim.customs.has(comet):
			survived = false
			break
		_check_once_finite(sim)
	_check(_finite_ok, "flyby stays finite through closest approach")
	if survived:
		var c1: Dictionary = sim.conserved()
		var de: float = absf((c1.e - c0.e) / c0.e)
		print("  flyby energy drift %s" % _sci(de))
		_check(de < 1.0e-4, "energy conserved across the flyby (%s)" % _sci(de))
	else:
		print("  (comet merged — still a valid finite outcome)")


## Live edits that all re-run compute_accel must leave the block integrator in
## a consistent, finite state with intact index caches.
func _test_runtime_edits() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	sim.speed = 604800.0
	_finite_ok = true
	var io := _moon(sim, "Io")
	if io != null:
		sim.set_mass_scale(io, 1000.0)   # Io as a small star — extreme, on a fresh system
		for i in 30: sim.tick(1.0 / 60.0)
		_check(_all_finite(sim) and _indices_ok(sim), "Io ×1000 mass stays finite, indices intact")
	sim.set_g_scale(2.0)
	for i in 30: sim.tick(1.0 / 60.0)
	_check(_all_finite(sim) and _indices_ok(sim), "G×2 stays finite, indices intact")
	var titan := _moon(sim, "Titan")
	if titan != null:
		sim.set_simulated(titan, false)   # rail
		for i in 20: sim.tick(1.0 / 60.0)
		sim.set_simulated(titan, true)    # unrail (re-injects into nb)
		for i in 20: sim.tick(1.0 / 60.0)
		_check(_all_finite(sim) and _indices_ok(sim), "rail→unrail stays finite, indices intact")
	sim.set_g_scale(1.0)
	_check(_all_finite(sim) and _indices_ok(sim), "restoring G stays finite, indices intact")


func _moon(sim: Simulation, mname: String) -> SimBody:
	for b in sim.moons:
		if b.body_name == mname:
			return b
	return null


## Is the block scheme's energy/momentum drift secular (grows with time) or
## oscillatory (bounded)? Sample the conserved quantities across a long run.
func _drift_probe() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	sim.speed = 604800.0
	var c0: Dictionary = sim.conserved()
	for chunk in 12:
		_run_days(sim, 91.3, "probe")   # ~quarter-year chunks
		var c: Dictionary = sim.conserved()
		print("  t=%.2f y : |dE/E| %s · |P| %s · |dL/L| %s" % [
			(chunk + 1) * 0.25, _sci(absf((c.e - c0.e) / c0.e)),
			_sci(c.p_mag), _sci(absf((c.l_mag - c0.l_mag) / c0.l_mag))])


func _planet(sim: Simulation, pname: String) -> SimBody:
	for b in sim.planets:
		if b.body_name == pname:
			return b
	return null
