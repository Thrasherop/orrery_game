extends Node
## Headless test for the real-scale view toggle:
##   godot --headless --path godot res://tests/real_scale_test.tscn
## Checks the linear display mapping in both sim modes, the trail-ends-on-body
## invariant, lossless round-tripping, and that the collision frame (nb.disp)
## never changes with the view.

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _tip_on_body(b: SimBody, sun: SimBody, days: float) -> float:
	var n := b.trail_size()
	if n == 0:
		return 0.0
	var tip: Vector3 = b.trail_verts[n - 1] + TrailFrames.anchor_now(b, sun, days)
	return tip.distance_to(b.display_pos)


func _ready() -> void:
	print("[real-scale] view toggle")
	Events.set_real_scale(false)
	Events.set_moon_trail_frame(false)
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)

	var sim := Simulation.new()
	add_child(sim)
	sim.tick(0.016)

	var earth: SimBody = null
	var neptune: SimBody = null
	for b in sim.planets:
		if b.body_name == "Earth":
			earth = b
		if b.body_name == "Neptune":
			neptune = b

	# --- Kepler mode ------------------------------------------------------
	var compressed_r: float = earth.display_pos.length()
	_check(absf(compressed_r - Units.dist_scale(earth.r_au)) < 0.01,
		"compressed view: Earth at dist_scale(r) (got %.2f)" % compressed_r)

	Events.set_real_scale(true)
	sim.tick(0.016)
	var days := SimTime.sim_days(sim.sim_ms)
	_check(earth.display_pos.distance_to(earth.pos_au * Units.REAL_AU) < 0.01,
		"real scale: Earth display is linear pos_au x %.1f" % Units.REAL_AU)
	_check(absf(neptune.display_pos.length() - neptune.r_au * Units.REAL_AU) < 0.01,
		"real scale: Neptune at %.0f units (30 AU linear)" % neptune.display_pos.length())
	_check(_tip_on_body(earth, sim.sun, days) < 0.5,
		"real scale: Earth trail ends on the body (off by %.4f)" % _tip_on_body(earth, sim.sun, days))

	# every path-frame mode keeps its semantics at real scale: lossless
	# switching and the trail-ends-on-body invariant in each frame
	for mode in TrailFrames.MODE_NAMES.size():
		Events.set_trail_mode(mode)
		_check(earth.trail_size() == earth.trail_verts.size(),
			"real scale mode %d: verts in lockstep" % mode)
		_check(_tip_on_body(earth, sim.sun, days) < 0.5,
			"real scale mode %d: trail ends on the body (off by %.4f)" % [mode, _tip_on_body(earth, sim.sun, days)])
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)

	# simulated moons ride their host at true offsets
	var moon_checked := false
	for mb: SimBody in sim.moons:
		if mb.body_name == "Moon" and mb.simulated and mb.host != null:
			var off: float = mb.display_pos.distance_to(mb.host.display_pos)
			_check(absf(off - mb.a_au * Units.REAL_AU) < 0.005,
				"real scale: the Moon sits %.4f units from Earth (a_au x %.1f)" % [off, Units.REAL_AU])
			moon_checked = true
	if not moon_checked:
		print("  --  (no simulated Moon; moon mapping unchecked in Kepler)")

	# toggling back is lossless
	Events.set_real_scale(false)
	sim.tick(0.016)
	days = SimTime.sim_days(sim.sim_ms)
	_check(absf(earth.display_pos.length() - Units.dist_scale(earth.r_au)) < 0.01,
		"toggle off: Earth back at compressed display")
	_check(_tip_on_body(earth, sim.sun, days) < 0.5,
		"toggle off: Earth trail ends on the body (off by %.4f)" % _tip_on_body(earth, sim.sun, days))

	# --- N-body mode ------------------------------------------------------
	var body := sim.add_custom_body({
		name = "TestBody", mass_e = 1.0, dist_au = 2.0,
		lon_deg = 90.0, lat_deg = 0.0, speed_kms = 21.1, dir_deg = 0.0,
	})
	sim.speed = 604800.0
	for i in range(120):
		sim.tick(1.0 / 60.0)
	_check(sim.physics_active, "physics mode active")

	Events.set_real_scale(true)
	for i in range(30):
		sim.tick(1.0 / 60.0)
	days = SimTime.sim_days(sim.sim_ms)
	var ei: int = sim.nb.index_of(earth)
	var bary: Vector3 = sim.nb.barycenter()
	_check(earth.display_pos.distance_to(sim.nb.bary_offset_au(ei, bary) * Units.REAL_AU) < 0.01,
		"real scale (physics): Earth display is linear barycentric")
	# the collision frame must NOT follow the view
	_check(absf(sim.nb.disp[ei].length() - Units.dist_scale(earth.r_au)) < 1.5,
		"real scale (physics): nb.disp stays compressed for collisions (%.1f)" % sim.nb.disp[ei].length())
	_check(_tip_on_body(earth, sim.sun, days) < 0.5,
		"real scale (physics): Earth trail ends on the body (off by %.4f)" % _tip_on_body(earth, sim.sun, days))
	_check(_tip_on_body(body, sim.sun, days) < 0.5,
		"real scale (physics): custom trail ends on the body (off by %.4f)" % _tip_on_body(body, sim.sun, days))

	# frame semantics survive at real scale: Sun-locked draws the HELIOCENTRIC
	# path (rel x K), Barycentric the honest barycentric one — they differ by
	# exactly the sun's own barycentric offset
	Events.selected = earth
	Events.selection_changed.emit(earth)
	for mode in TrailFrames.MODE_NAMES.size():
		Events.set_trail_mode(mode)
		_check(_tip_on_body(earth, sim.sun, days) < 0.5,
			"real scale (physics) mode %d: trail ends on the body (off by %.4f)" % [mode, _tip_on_body(earth, sim.sun, days)])
	Events.selected = null
	Events.selection_changed.emit(null)
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)
	var n_e := earth.trail_size()
	var v_local: Vector3 = earth.trail_verts[n_e - 1]
	_check(v_local.distance_to(earth.trail_rel[n_e - 1] * Units.REAL_AU) < 1e-6,
		"real scale: Sun-locked vertex is the heliocentric sample x %.1f" % Units.REAL_AU)
	Events.set_trail_mode(TrailFrames.MODE_INERTIAL)
	var v_bary: Vector3 = earth.trail_verts[n_e - 1]
	var sun_off: Vector3 = (earth.trail_bary[n_e - 1] - earth.trail_rel[n_e - 1]) * Units.REAL_AU
	_check((v_bary - v_local).distance_to(sun_off) < 1e-6,
		"real scale: Sun-locked vs Barycentric differ by the sun's offset")
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)
	for mb: SimBody in sim.moons:
		if mb.body_name == "Moon" and mb.simulated and mb.host != null and mb.bind_t >= 1.0:
			var off2: float = mb.display_pos.distance_to(mb.host.display_pos)
			_check(off2 < 3.0 * mb.a_au * Units.REAL_AU,
				"real scale (physics): the Moon rides its host at true offset (%.4f units)" % off2)
			_check(_tip_on_body(mb, sim.sun, days) < 0.1,
				"real scale (physics): Moon trail ends on the body (off by %.4f)" % _tip_on_body(mb, sim.sun, days))
			# moon-frame toggle: Sun-locked moon trails re-anchor on the sun
			# and still end on the moon
			_check(TrailFrames.anchor_now(mb, sim.sun, days).distance_to(mb.host.display_pos) < 1e-9,
				"moon paths default: Sun-locked anchors the Moon's trail on its host")
			Events.set_moon_trail_frame(true)
			_check(TrailFrames.anchor_now(mb, sim.sun, days).distance_to(sim.sun.display_pos) < 1e-9,
				"moon-frame on: Sun-locked anchors the Moon's trail on the sun")
			_check(_tip_on_body(mb, sim.sun, days) < 0.1,
				"moon-frame on: Moon trail still ends on the body (off by %.4f)" % _tip_on_body(mb, sim.sun, days))
			Events.set_moon_trail_frame(false)

	# --- drift epoch: float32 jitter guard ------------------------------
	# In the drift modes the mesh stores GAL_V*(day − epoch); without the
	# rolling rebase the term reaches ~1600 units at the current sim date and
	# its float32 quantization jitters a true-scale planet's trail visibly.
	Events.set_trail_mode(TrailFrames.MODE_TRUE)
	sim.speed = 31557600.0   # 1 year/s — sail past the 300-day rebase window
	for i in range(90):
		sim.tick(1.0 / 60.0)
	sim.speed = 604800.0     # slow down so a fresh sample lands near "now"
	for i in range(30):
		sim.tick(1.0 / 60.0)
	days = SimTime.sim_days(sim.sim_ms)
	_check(absf(days - TrailFrames.drift_epoch) <= 320.0,
		"drift epoch rides along with sim time (lag %.0f d)" % absf(days - TrailFrames.drift_epoch))
	var n_d := earth.trail_size()
	_check(earth.trail_verts[n_d - 1].length() < 500.0,
		"drift-mode head vertex stays float32-small (%.0f units)" % earth.trail_verts[n_d - 1].length())
	_check(_tip_on_body(earth, sim.sun, days) < 0.5,
		"drift-mode trail still ends on the body after rebases (off by %.4f)" % _tip_on_body(earth, sim.sun, days))
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)

	# round-trip back to compressed
	Events.set_real_scale(false)
	for i in range(30):
		sim.tick(1.0 / 60.0)
	days = SimTime.sim_days(sim.sim_ms)
	_check(earth.display_pos.distance_to(sim.nb.disp[sim.nb.index_of(earth)]) < 0.01,
		"toggle off (physics): Earth back on the sun-anchored display")
	_check(_tip_on_body(earth, sim.sun, days) < 0.5,
		"toggle off (physics): Earth trail ends on the body (off by %.4f)" % _tip_on_body(earth, sim.sun, days))
	_check(_tip_on_body(body, sim.sun, days) < 0.5,
		"toggle off (physics): custom trail ends on the body (off by %.4f)" % _tip_on_body(body, sim.sun, days))

	# moon-frame toggle holds in the compressed view too
	Events.set_moon_trail_frame(true)
	for mb: SimBody in sim.moons:
		if mb.body_name == "Moon" and mb.simulated and mb.host != null and mb.bind_t >= 1.0:
			_check(_tip_on_body(mb, sim.sun, days) < 0.5,
				"moon-frame (compressed): Moon trail ends on the body (off by %.4f)" % _tip_on_body(mb, sim.sun, days))
	Events.set_moon_trail_frame(false)

	if _failures == 0:
		print("[real-scale] ALL PASSED")
	else:
		printerr("[real-scale] %d FAILURES" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
