extends Node
## Headless test for the per-body simulation toggle ("rails") and friends:
##   godot --headless --path godot res://tests/rails_test.tscn
## - custom moons work with the global "Simulate moons" flag OFF
## - set_simulated(false) freezes a body onto a kinematic circular rail,
##   releases physics when nothing simulated remains, and survives saves
## - set_simulated(true) re-injects the body into live gravity
## - step_costs() names the bodies forcing small substeps (Io & friends)

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _planet(sim: Simulation, pname: String) -> SimBody:
	for b in sim.planets:
		if b.body_name == pname:
			return b
	return null


func _moon_named(sim: Simulation, mname: String) -> SimBody:
	for b in sim.moons:
		if b.body_name == mname:
			return b
	return null


func _ready() -> void:
	print("[rails_test] custom moon with global moons flag OFF")
	var sim := Simulation.new()
	add_child(sim)
	sim.moons_simulated = false
	sim._rebuild_moons()
	sim.tick(0.016)
	var earth := _planet(sim, "Earth")
	var moon := sim.add_custom_body({
		name = "Probe", mass_e = 0.01, dist_au = 2.6e-3,
		lon_deg = 0.0, lat_deg = 0.0,
		speed_kms = sim.circ_speed_kms(2.6e-3, earth), dir_deg = 0.0, host = earth,
	})
	_check(sim.physics_active, "adding a moon enters physics despite moons off")
	_check(moon.simulated, "new bodies are simulated by default")
	sim.speed = 86400.0 * 2.0
	for i in 60:
		sim.tick(0.016)
	_check(moon.host == earth, "moon bound to Earth")
	var rel := moon.pos_au - earth.pos_au
	_check(rel.length() > 1.5e-3 and rel.length() < 4.0e-3,
			"moon orbits at ~2.6e-3 AU (got %.5f)" % rel.length())

	print("[rails_test] rail the moon")
	sim.set_simulated(moon, false)
	_check(not moon.simulated, "moon marked unsimulated")
	_check(not sim.physics_active, "physics released — nothing simulated remains")
	_check(_moon_named(sim, "Probe") == moon, "railed moon still exists in the rail list")
	sim.tick(0.016)
	var rel0 := moon.pos_au - earth.pos_au
	for i in 120:
		sim.tick(0.016)
	var rel1 := moon.pos_au - earth.pos_au
	_check(absf(rel1.length() - rel0.length()) < 1e-6,
			"railed orbit radius is frozen (Δ %.8f AU)" % absf(rel1.length() - rel0.length()))
	_check(rad_to_deg(rel0.angle_to(rel1)) > 20.0,
			"railed moon keeps gliding (swept %.1f°)" % rad_to_deg(rel0.angle_to(rel1)))
	var disp_rel := (moon.display_pos - earth.display_pos).length()
	_check(absf(disp_rel - moon.rail_a * moon.disp_k) < 0.05,
			"railed moon renders at the amplified display distance")

	print("[rails_test] railed mass slider stays inert")
	sim.set_mass_scale(moon, 3.0)
	_check(not sim.physics_active, "mass edit on a railed body doesn't start physics")
	_check(moon.mass_scale == 3.0, "mass scale stored for later")
	sim.set_mass_scale(moon, 1.0)

	print("[rails_test] Kepler-mode save with a railed body")
	var snap := Snapshot.capture(sim, null)
	_check(int(snap.version) == 3, "snapshot is v3")
	_check(Snapshot.validate(snap), "snapshot validates")
	var json: Dictionary = JSON.parse_string(JSON.stringify(snap, "", false, true))
	_check(Snapshot.apply(sim, null, json), "snapshot applies after JSON round trip")
	earth = _planet(sim, "Earth")
	var moon2 := _moon_named(sim, "Probe")
	_check(moon2 != null and not moon2.simulated, "railed moon restored as railed")
	_check(not sim.physics_active, "restored save stays in Kepler mode")
	sim.tick(0.016)
	var rl0 := moon2.pos_au - earth.pos_au
	for i in 60:
		sim.tick(0.016)
	var rl1 := moon2.pos_au - earth.pos_au
	_check(absf(rl1.length() - rl0.length()) < 1e-6 and rl0.angle_to(rl1) > 0.1,
			"restored railed moon glides on its circle")

	print("[rails_test] unrail — back into live gravity")
	sim.set_simulated(moon2, true)
	_check(moon2.simulated and sim.physics_active, "re-simulating enters physics")
	_check(sim.nb.index_of(moon2) >= 0, "body re-injected into the integrator")
	for i in 60:
		sim.tick(0.016)
	var rel2 := moon2.pos_au - earth.pos_au
	_check(rel2.length() > 1.5e-3 and rel2.length() < 4.0e-3,
			"unrailed moon still orbits Earth (r %.5f AU)" % rel2.length())
	_check(moon2.host == earth, "unrailed moon re-bound to Earth")

	print("[rails_test] step costs (Io & friends)")
	var sim2 := Simulation.new()
	add_child(sim2)
	sim2.moons_simulated = true
	sim2.sim_expensive_moons = true
	sim2._rebuild_moons()
	sim2.tick(0.016)
	sim2.add_custom_body({
		name = "Far", mass_e = 1.0, dist_au = 3.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 17.2, dir_deg = 0.0,
	})
	var costs := sim2.step_costs()
	_check(not costs.is_empty(), "tight moons show up as step costs")
	_check(costs[0].body.body_name == "Io", "Io tops the list (got %s)" % costs[0].body.body_name)
	_check(costs[0].factor > 5.0, "Io forces >5x substeps (×%.1f)" % costs[0].factor)
	var sorted_ok := true
	for k in range(1, costs.size()):
		if costs[k].factor > costs[k - 1].factor:
			sorted_ok = false
	_check(sorted_ok, "costs sorted worst-first")

	print("[rails_test] rail a catalog moon during physics")
	var io := _moon_named(sim2, "Io")
	var jup := _planet(sim2, "Jupiter")
	var nb_before := sim2.nb.count()
	sim2.set_simulated(io, false)
	_check(sim2.physics_active, "physics stays (a custom body is still simulated)")
	_check(sim2.nb.count() == nb_before - 1, "railed Io left the integrator")
	var still_listed := false
	for c in sim2.step_costs():
		if c.body == io:
			still_listed = true
	_check(not still_listed, "railed Io no longer costs steps")
	_check(not "Io" in sim2.decorative_moon_names(jup), "railed Io isn't double-drawn as decoration")
	for i in 60:
		sim2.tick(0.016)
	var io_rel := io.pos_au - jup.pos_au
	_check(absf(io_rel.length() - io.rail_a) < 1e-6, "railed Io glides around Jupiter")

	print("[rails_test] physics-mode save with mixed railed + simulated")
	var snap2 := Snapshot.capture(sim2, null)
	_check(Snapshot.validate(snap2), "mixed snapshot validates")
	var json2: Dictionary = JSON.parse_string(JSON.stringify(snap2, "", false, true))
	_check(Snapshot.apply(sim2, null, json2), "mixed snapshot applies")
	io = _moon_named(sim2, "Io")
	jup = _planet(sim2, "Jupiter")
	_check(io != null and not io.simulated, "Io restored railed")
	_check(sim2.physics_active and sim2.nb.index_of(io) < 0, "restored Io outside the integrator")
	sim2.tick(0.016)
	var ior0 := io.pos_au - jup.pos_au
	for i in 60:
		sim2.tick(0.016)
	var ior1 := io.pos_au - jup.pos_au
	_check(absf(ior1.length() - ior0.length()) < 1e-6, "restored railed Io still glides")

	print("[rails_test] Kepler-mode rail/unrail of a catalog moon is seamless")
	var sim3 := Simulation.new()
	add_child(sim3)
	sim3.moons_simulated = true
	sim3._rebuild_moons()
	sim3.tick(0.016)
	var luna := _moon_named(sim3, "Moon")
	var earth3 := _planet(sim3, "Earth")
	sim3.set_simulated(luna, false)
	_check(not sim3.physics_active, "railing a Kepler moon doesn't start physics")
	for i in 30:
		sim3.tick(0.016)
	var before := luna.pos_au - earth3.pos_au
	sim3.set_simulated(luna, true)
	_check(not sim3.physics_active, "un-railing a Kepler moon doesn't start physics either")
	sim3.tick(0.0)
	var after := luna.pos_au - earth3.pos_au
	_check((after - before).length() < 1e-5,
			"analytic circle resumes seamlessly (jump %.8f AU)" % (after - before).length())

	print("[rails_test] %s" % ("ALL PASSED" if _failures == 0 else "%d FAILED" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
