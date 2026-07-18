extends Node
## Headless test for the moon update (simulated moons):
##   godot --headless --path godot res://tests/moons_test.tscn
## Covers Kepler kinematics, seamless physics seeding, emergent orbital
## periods, the substep budget, moon-host merging, host stealing and the
## v2 snapshot round-trip (+ v1 compatibility).

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _moon_of(sim: Simulation, mname: String) -> SimBody:
	for b in sim.moons:
		if b.body_name == mname:
			return b
	return null


func _planet(sim: Simulation, pname: String) -> SimBody:
	for b in sim.planets:
		if b.body_name == pname:
			return b
	return null


## fresh sim with a deterministic moon setup (independent of user prefs)
func _make_sim(moons_on: bool, expensive_on: bool) -> Simulation:
	var sim := Simulation.new()
	add_child(sim)
	if sim.sim_expensive_moons != expensive_on:
		sim.set_expensive_moons(expensive_on)
	if sim.moons_simulated != moons_on:
		sim.set_moons_simulated(moons_on)
	sim.tick(0.016)
	return sim


## enter physics without making it permanent: a tiny far-away custom body
func _enter_physics(sim: Simulation) -> SimBody:
	return sim.add_custom_body({
		name = "Trigger", mass_e = 0.0001, dist_au = 40.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 4.7, dir_deg = 0.0,
	})


func _ready() -> void:
	print("[moons_test] kepler kinematics")
	_test_kepler()
	print("[moons_test] flags")
	_test_flags()
	print("[moons_test] physics seeding + emergent period")
	_test_physics()
	print("[moons_test] substep budget")
	_test_budget()
	print("[moons_test] moon-host merge")
	_test_merge()
	print("[moons_test] host stealing + escape")
	_test_steal()
	print("[moons_test] snapshot v2 + v1 compat")
	_test_snapshot()
	print("[moons_test] %s" % ("ALL PASSED" if _failures == 0 else "%d FAILURES" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _test_kepler() -> void:
	var sim := _make_sim(true, true)
	_check(sim.moons.size() == 7, "7 catalog moons simulated (got %d)" % sim.moons.size())
	_check(sim.all_bodies().size() == 16, "all_bodies = 16 (got %d)" % sim.all_bodies().size())

	var moon := _moon_of(sim, "Moon")
	var earth := _planet(sim, "Earth")
	_check(moon != null and earth != null, "Moon + Earth present")
	var disp_d := (moon.display_pos - earth.display_pos).length()
	_check(absf(disp_d - 2.3) < 0.05, "Moon renders at catalog display distance (%.3f vs 2.3)" % disp_d)
	var real_d := (moon.pos_au - earth.pos_au).length()
	_check(absf(real_d - 0.002570) < 1e-5, "Moon physics distance is real a (%.6f AU)" % real_d)
	_check(absf(moon.period_days - 27.32) < 0.5, "derived period ≈ 27.3 d (got %.2f)" % moon.period_days)

	# advancing exactly one derived period returns the moon to the same phase
	var rel0 := (moon.pos_au - earth.pos_au).normalized()
	sim.sim_ms += moon.period_days * 86400000.0
	sim.tick(0.0)
	var rel1 := (moon.pos_au - earth.pos_au).normalized()
	_check(rel0.dot(rel1) > 0.999, "kinematic phase repeats after one period (dot %.5f)" % rel0.dot(rel1))

	# retrograde: Triton sweeps the opposite way from a prograde moon
	var triton := _moon_of(sim, "Triton")
	_check(triton != null and triton.orbit_sign < 0.0, "Triton is retrograde")


func _test_flags() -> void:
	var sim := _make_sim(true, false)
	_check(sim.moons.size() == 4, "expensive moons excluded (got %d, want 4)" % sim.moons.size())
	_check(_moon_of(sim, "Io") == null and _moon_of(sim, "Callisto") != null, "Io decorative, Callisto simulated")
	var jup := _planet(sim, "Jupiter")
	var deco := sim.decorative_moon_names(jup)
	_check("Io" in deco and "Europa" in deco and not ("Ganymede" in deco), "decorative names = excluded expensive")

	sim.set_expensive_moons(true)
	_check(sim.moons.size() == 7, "re-enabling fast moons restores 7")
	sim.set_moons_simulated(false)
	_check(sim.moons.is_empty(), "toggle off removes all simulated moons")
	var earth := _planet(sim, "Earth")
	_check(sim.decorative_moon_names(earth) == ["Moon"], "all moons decorative when off")

	# locked once physics starts
	sim.set_moons_simulated(true)
	_enter_physics(sim)
	sim.set_moons_simulated(false)
	_check(sim.moons_simulated, "moons flag locked in physics mode")
	sim.set_expensive_moons(false)
	_check(sim.sim_expensive_moons, "expensive flag locked in physics mode")


func _test_physics() -> void:
	var sim := _make_sim(true, true)
	var moon := _moon_of(sim, "Moon")
	var earth := _planet(sim, "Earth")
	# measure relative to Earth: entering physics shifts the whole display
	# frame slightly (the sun takes up its barycentric wobble), which is
	# pre-existing behavior and not a moon-seeding artifact
	var rel_before: Vector3 = moon.display_pos - earth.display_pos

	_enter_physics(sim)
	sim.tick(0.0)
	var jump := ((moon.display_pos - earth.display_pos) - rel_before).length()
	_check(jump < 0.05, "seeding is seamless on screen (jump %.4f units)" % jump)
	_check(moon.host == earth, "Moon seeded bound to Earth")

	# emergent period: sweep angle over one kinematic period of N-body time
	sim.speed = 86400.0   # 1 day/s
	var prev := (moon.pos_au - earth.pos_au).normalized()
	var swept := 0.0
	var t0 := sim.sim_ms
	while sim.sim_ms - t0 < moon.period_days * 86400000.0:
		sim.tick(1.0 / 60.0)
		var cur := (moon.pos_au - earth.pos_au).normalized()
		swept += prev.angle_to(cur)
		prev = cur
	_check(absf(swept - TAU) / TAU < 0.05,
		"Moon sweeps one full orbit per period under gravity (%.2f rad vs %.2f)" % [swept, TAU])
	var d_after := (moon.pos_au - earth.pos_au).length()
	_check(absf(d_after - 0.002570) / 0.002570 < 0.1,
		"Moon orbit radius stable under gravity (%.6f AU)" % d_after)
	var io := _moon_of(sim, "Io")
	_check(io != null and io.host != null and io.host.body_name == "Jupiter",
		"Io still bound to Jupiter after %d days" % int(moon.period_days))


func _test_budget() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	# Year/s used to saturate the substep budget; the compiled kernel (when
	# present) now keeps up at full speed here — either way the frame stays cheap.
	sim.speed = 31557600.0   # Year/s
	var t0 := Time.get_ticks_msec()
	for i in 10:
		sim.tick(1.0 / 60.0)
	var elapsed := Time.get_ticks_msec() - t0
	_check(elapsed < 3000, "10 Year/s ticks stay within budget (%d ms)" % elapsed)
	# Push far past what even the fast kernel can integrate in one frame — the
	# lag mechanism must still engage and report the shortfall.
	sim.speed = 31557600.0 * 60.0   # 60 years/s
	for i in 20:
		sim.tick(1.0 / 60.0)
	_check(sim.lag_ratio < 0.95, "extreme speed still engages the lag mechanism (ratio %.2f)" % sim.lag_ratio)


func _test_merge() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	var moon := _moon_of(sim, "Moon")
	var earth := _planet(sim, "Earth")
	# kill the Moon's orbital velocity — it free-falls into Earth (~5 days)
	var mi := sim.nb.index_of(moon)
	var hi := sim.nb.index_of(earth)
	sim.nb.vx[mi] = sim.nb.vx[hi]
	sim.nb.vy[mi] = sim.nb.vy[hi]
	sim.nb.vz[mi] = sim.nb.vz[hi]
	sim.nb.compute_accel(sim.g_scale)
	sim.speed = 86400.0
	for i in range(60 * 12):
		sim.tick(1.0 / 60.0)
		if _moon_of(sim, "Moon") == null:
			break
	_check(_moon_of(sim, "Moon") == null, "stalled Moon merges into Earth")
	_check(_planet(sim, "Earth") != null, "Earth survives the impact")
	_check(sim.physics_permanent, "merger locks N-body mode")


func _test_steal() -> void:
	var sim := _make_sim(true, true)
	_enter_physics(sim)
	var moon := _moon_of(sim, "Moon")
	# park a 5000 M⊕ thief right next to the Moon, co-moving
	var thief := sim.add_custom_body({
		name = "Thief", mass_e = 5000.0, dist_au = 1.5,
		lon_deg = 180.0, lat_deg = 0.0, speed_kms = 24.0, dir_deg = 0.0,
	})
	var mi := sim.nb.index_of(moon)
	var ti := sim.nb.index_of(thief)
	sim.nb.px[ti] = sim.nb.px[mi] + 0.0015
	sim.nb.py[ti] = sim.nb.py[mi]
	sim.nb.pz[ti] = sim.nb.pz[mi]
	sim.nb.vx[ti] = sim.nb.vx[mi]
	sim.nb.vy[ti] = sim.nb.vy[mi]
	sim.nb.vz[ti] = sim.nb.vz[mi]
	sim.nb.compute_accel(sim.g_scale)
	sim.tick(0.0)
	_check(moon.host == thief, "Moon stolen by the nearer heavy body")
	_check(sim.physics_permanent, "catalog-moon steal locks N-body mode")
	_check(moon.disp_k != moon.catalog_disp_k, "capture uses a fresh display amplification")

	# fling the moon far outside every Hill sphere → it goes free
	sim.nb.px[mi] += 3.0
	sim.nb.pz[mi] += 3.0
	sim.nb.compute_accel(sim.g_scale)
	sim.tick(0.0)
	_check(moon.host == null, "far-flung moon escapes (host = null)")

	# snapshot round-trip with a stolen/free state
	var rig := CameraRig.new()
	add_child(rig)
	var snap := Snapshot.capture(sim, rig)
	_check(Snapshot.validate(snap), "post-steal snapshot validates")
	var parsed = JSON.parse_string(JSON.stringify(snap, "", false, true))
	_check(Snapshot.apply(sim, rig, parsed), "post-steal snapshot applies")
	var moon2 := _moon_of(sim, "Moon")
	_check(moon2 != null and moon2.host == null, "free moon restored as free")
	var io2 := _moon_of(sim, "Io")
	_check(io2 != null and io2.host != null and io2.host.body_name == "Jupiter", "Io restored bound to Jupiter")


func _test_snapshot() -> void:
	# Kepler-mode round trip: moons regenerate from the catalog
	var sim := _make_sim(true, false)
	var rig := CameraRig.new()
	add_child(rig)
	var snap := Snapshot.capture(sim, rig)
	_check(Snapshot.validate(snap), "kepler v2 snapshot validates")
	_check((snap.moons as Array).is_empty(), "kepler snapshot carries no moon rows")
	var parsed = JSON.parse_string(JSON.stringify(snap, "", false, true))
	_check(Snapshot.apply(sim, rig, parsed), "kepler v2 snapshot applies")
	_check(sim.moons_simulated and not sim.sim_expensive_moons, "moon flags restored")
	_check(sim.moons.size() == 4, "kepler moons regenerated per flags (got %d)" % sim.moons.size())

	# custom moon round trip
	var mars := _planet(sim, "Mars")
	sim.set_expensive_moons(true)
	var pet := sim.add_custom_body({
		name = "Pet", mass_e = 0.01, dist_au = 0.002,
		lon_deg = 0.0, lat_deg = 0.0,
		speed_kms = sim.circ_speed_kms(0.002, mars), dir_deg = 0.0,
		host = mars,
	})
	_check(pet.is_moon and pet.host == mars, "custom moon bound to Mars")
	_check(sim.physics_active, "adding a moon enters physics")
	var snap2 := Snapshot.capture(sim, rig)
	var parsed2 = JSON.parse_string(JSON.stringify(snap2, "", false, true))
	_check(Snapshot.apply(sim, rig, parsed2), "custom-moon snapshot applies")
	var pet2 := _moon_of(sim, "Pet")
	_check(pet2 != null and pet2.custom and pet2.host != null and pet2.host.body_name == "Mars",
		"custom moon restored under Mars")
	sim.remove_moon(pet2)
	_check(not sim.physics_active, "removing the last custom moon restores Kepler mode")

	# v1 saves (pre-moon-update) load with moons off
	var v1 := {
		version = 1,
		sim = {
			sim_ms = Time.get_unix_time_from_system() * 1000.0,
			speed = 604800.0, playing = true, g_scale = 1.0,
			physics_active = false, physics_permanent = false, custom_count = 0,
		},
		sun = { mass_scale = 1.0 },
		planets = [],
		customs = [],
	}
	for def in Catalog.make_planets():
		v1.planets.append({ name = def.body_name, size = def.size, mass_scale = 1.0 })
	_check(Snapshot.validate(v1), "v1 snapshot still validates")
	_check(Snapshot.apply(sim, rig, v1), "v1 snapshot applies")
	_check(not sim.moons_simulated and sim.moons.is_empty(), "v1 load = moons off")
