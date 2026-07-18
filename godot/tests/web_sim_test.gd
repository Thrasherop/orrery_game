extends Node
## Web integration test: drives the REAL Simulation through the native WASM
## path (JavaScriptBridge → nbody.wasm) and checks it against a GDScript-forced
## copy in the same browser — correctness (physics matches) + end-to-end speedup
## including marshalling. Sentinels: WEB_SIM_RESULT / WEB_SIM_ERROR / WEB_SIM_DONE.

const EPOCH_MS := 1767225600000.0
var _phase := 0
var _wait := 0.0
var _sim_native: Simulation


func _ready() -> void:
	if not OS.has_feature("web"):
		print("WEB_SIM skipped (not a web export)")
		print("WEB_SIM_DONE")
		return
	_sim_native = _make_sim()   # kernel active (web WASM)


func _make_sim() -> Simulation:
	var s := Simulation.new()
	add_child(s)
	s.sim_ms = EPOCH_MS
	if not s.moons_simulated:
		s.set_moons_simulated(true)
	s.tick(0.0)
	s.add_custom_body({ name = "Trigger", mass_e = 0.0001, dist_au = 40.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 4.7, dir_deg = 0.0 })
	return s


func _process(dt: float) -> void:
	if _phase >= 2:
		return
	if _phase == 0:
		_wait += dt
		if _sim_native._kernel != null and _sim_native._kernel.ready():
			_phase = 1
		elif _wait > 20.0:
			print("WEB_SIM_ERROR native kernel never became ready")
			print("WEB_SIM_DONE")
			_phase = 2
	elif _phase == 1:
		_run()
		_phase = 2
		print("WEB_SIM_DONE")


func _run() -> void:
	print("WEB_SIM backend=", _sim_native._kernel.backend_name())
	# GDScript-forced twin, seeded identically
	var sim_gd := _make_sim()
	sim_gd._kernel = null   # force the GDScript integrator

	# --- correctness: same dt sequence through both, compare physics ---
	var frames := 40
	_sim_native.speed = 604800.0
	sim_gd.speed = 604800.0
	for k in frames:
		_sim_native.tick(1.0 / 60.0)
		sim_gd.tick(1.0 / 60.0)
	var na = _sim_native.nb
	var gd = sim_gd.nb
	var max_dp := 0.0
	var n = mini(na.count(), gd.count())
	for i in n:
		max_dp = maxf(max_dp, absf(na.px[i] - gd.px[i]))
		max_dp = maxf(max_dp, absf(na.py[i] - gd.py[i]))
		max_dp = maxf(max_dp, absf(na.pz[i] - gd.pz[i]))
	var e_native: Dictionary = _sim_native.conserved()
	var e_gd: Dictionary = sim_gd.conserved()

	# --- speedup at week/s (marshalling-dominated, few blocks/frame) ---
	var us_native_wk := _time_ticks(_sim_native, 604800.0, 150)
	var us_gd_wk := _time_ticks(sim_gd, 604800.0, 150)
	# --- speedup at Year/s (the target speed; block work dominates) ---
	var us_native_yr := _time_ticks(_sim_native, 31557600.0, 100)
	var lag_native := _sim_native.lag_ratio
	var us_gd_yr := _time_ticks(sim_gd, 31557600.0, 100)
	var lag_gd := sim_gd.lag_ratio

	print("WEB_SIM_RESULT backend=%s max_dpos=%s dE=%s" % [
		_sim_native._kernel.backend_name(), _sci(max_dp),
		_sci(absf(e_native.get("e", 0.0) - e_gd.get("e", 0.0)))])
	print("WEB_SIM_SPEED week/s: native %.0fus gd %.0fus (%.1fx) | Year/s: native %.0fus (lag %.2f) gd %.0fus (lag %.2f) (%.1fx)" % [
		us_native_wk, us_gd_wk, us_gd_wk / maxf(us_native_wk, 0.001),
		us_native_yr, lag_native, us_gd_yr, lag_gd, us_gd_yr / maxf(us_native_yr, 0.001)])


func _time_ticks(s: Simulation, speed: float, batch: int) -> float:
	s.speed = speed
	s.tick(1.0 / 60.0)   # warm
	var t0 := Time.get_ticks_usec()
	for k in batch:
		s.tick(1.0 / 60.0)
	return float(Time.get_ticks_usec() - t0) / float(batch)


func _sci(x: float) -> String:
	if x == 0.0:
		return "0"
	var neg := x < 0.0
	var ax := absf(x)
	var e := floori(log(ax) / log(10.0))
	return "%s%.3fe%d" % ["-" if neg else "", ax / pow(10.0, e), e]
