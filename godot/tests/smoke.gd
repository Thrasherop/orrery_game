extends Node
## Headless smoke test for the simulation core (no rendering needed):
##   godot --headless --path godot res://tests/smoke.tscn
## Checks Kepler positions, N-body seeding/stepping, trails and mergers.

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _ready() -> void:
	print("[smoke] simulation core")

	var sim := Simulation.new()
	add_child(sim)

	# --- Kepler mode ------------------------------------------------------
	sim.tick(0.016)
	var earth: SimBody = null
	var mercury: SimBody = null
	for b in sim.planets:
		if b.body_name == "Earth":
			earth = b
		if b.body_name == "Mercury":
			mercury = b
	_check(earth != null and mercury != null, "planet catalog present (%d planets)" % sim.planets.size())
	_check(absf(earth.r_au - 1.0) < 0.02, "Earth at ~1 AU (got %.4f)" % earth.r_au)
	_check(earth.vel_kms > 28.0 and earth.vel_kms < 31.0, "Earth at ~29.8 km/s (got %.2f)" % earth.vel_kms)
	_check(mercury.r_au > 0.3 and mercury.r_au < 0.47, "Mercury within its orbit range (got %.4f)" % mercury.r_au)
	_check(earth.trail_points.size() == earth.trail_max, "Earth trail backfilled (%d pts)" % earth.trail_points.size())
	_check(not sim.physics_active, "starts in Kepler ephemeris mode")

	# --- N-body mode ------------------------------------------------------
	var body := sim.add_custom_body({
		name = "TestBody", mass_e = 1.0, dist_au = 2.0,
		lon_deg = 90.0, lat_deg = 0.0, speed_kms = 21.1, dir_deg = 0.0,
	})
	_check(sim.physics_active, "adding a body switches to N-body gravity")
	_check(absf(body.r_au - 2.0) < 0.05, "custom body injected at ~2 AU (got %.4f)" % body.r_au)

	# a simulated year at one week per real second
	var r0: float = earth.r_au
	sim.speed = 604800.0
	for i in range(60 * 52):
		sim.tick(1.0 / 60.0)
	_check(absf(earth.r_au - r0) < 0.05,
		"Earth orbit stable after 1 simulated year of N-body (Δr = %.5f AU)" % absf(earth.r_au - r0))
	_check(body.trail_points.size() > 10, "custom body leaves a trail (%d pts)" % body.trail_points.size())

	# removing the custom body should snap back to the ephemeris
	sim.remove_custom_body(body)
	_check(not sim.physics_active, "removing the last custom body restores Kepler mode")

	# --- merger -----------------------------------------------------------
	var merges := []
	Events.merged.connect(func(s, l, _p, _c, _sc) -> void: merges.append([s, l]))
	var bullet := sim.add_custom_body({
		name = "Bullet", mass_e = 5.0, dist_au = 1.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 0.0, dir_deg = 0.0,
	})
	# no tangential speed → falls straight into the sun
	sim.speed = 2629800.0
	for i in range(60 * 30):
		sim.tick(1.0 / 60.0)
		if not merges.is_empty():
			break
	_check(not merges.is_empty(), "dropped body merges into the sun")
	if not merges.is_empty():
		_check(merges[0][0] == sim.sun, "the sun survives the merger")
	_check(sim.physics_permanent, "merger makes N-body mode permanent")
	_check(bullet != null and sim.customs.is_empty(), "merged body removed from the system")

	print("[smoke] %s" % ("ALL PASSED" if _failures == 0 else "%d FAILURES" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
