extends Node
## Investigates the "kink in Neptune's galaxy-view trail" during a binary.
## Measures path curvature at TRAIL spacing (not per-frame — that oversamples
## and hides it) for Neptune's real trajectory vs each display frame, to see
## whether the kink is in the physics or added by the view.

const EPOCH_MS := 1767225600000.0
const STRIDE := 220   # frames per coarse sample ≈ Neptune's ~118-day trail interval


func _ready() -> void:
	var sim := Simulation.new()
	add_child(sim)
	sim.sim_ms = EPOCH_MS
	sim.tick(0.0)
	var body1 := sim.add_custom_body({
		name = "Body 1", mass_e = 160000.0, dist_au = 3.5,   # ~0.48 solar masses
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 13.0, dir_deg = 0.0,
	})
	var nb = sim.nb
	var neptune := _planet(sim, "Neptune")

	sim.speed = 2629800.0
	var raw: Array[Vector3] = []       # Neptune real barycentric position
	var faithful: Array[Vector3] = []  # honest single compression of it
	var v_local: Array[Vector3] = []   # "Sun-locked" trail vertex
	var v_inert: Array[Vector3] = []   # "True motion" trail vertex
	var v_galaxy: Array[Vector3] = []  # "Galaxy" trail vertex
	var v_true: Array[Vector3] = []    # "Real space" (MODE_TRUE) trail vertex
	var min_sep := INF
	var sun_peak_kms := 0.0

	for f in 4400:
		sim.tick(1.0 / 60.0)
		var bi := nb.index_of(body1)
		var ni := nb.index_of(neptune)
		if not sim.physics_active or bi < 0 or ni < 0:
			print("KINK_TEST_ERROR binary merged at frame %d — too eccentric" % f)
			break
		if f % STRIDE != 0:
			continue
		var day := SimTime.sim_days(sim.sim_ms)
		var bary := nb.barycenter()
		var nbary := Vector3(nb.px[ni], nb.py[ni], nb.pz[ni]) - bary
		var anchor: Vector3 = nb.disp[0]           # sun's absolute display pos
		var local: Vector3 = nb.disp[ni] - nb.disp[0]
		raw.append(nbary)
		faithful.append(Units.to_display(nbary))
		v_local.append(local)                       # MODE_LOCAL
		v_inert.append(anchor + local)              # MODE_INERTIAL
		v_galaxy.append(anchor + local + TrailFrames.GAL_V * day)  # MODE_GALAXY
		v_true.append(Units.to_display(nbary) + TrailFrames.GAL_V * day)  # MODE_TRUE
		min_sep = minf(min_sep, nb.real_distance(0, bi))
		sun_peak_kms = maxf(sun_peak_kms, Vector3(nb.vx[0], nb.vy[0], nb.vz[0]).length() * Units.KMS_PER_AUDAY)

	print("KINK_TEST coarse samples=%d  min sep=%.2f AU  sun peak=%.1f km/s" % [
		raw.size(), min_sep, sun_peak_kms])
	print("  peak turning angle at trail spacing (a kink = a big value):")
	print("    Neptune REAL trajectory (barycentric) : %.1f deg" % _peak_turn_deg(raw))
	print("    Neptune faithful compression          : %.1f deg" % _peak_turn_deg(faithful))
	print("    Neptune 'Sun-locked' view             : %.1f deg" % _peak_turn_deg(v_local))
	print("    Neptune 'True motion' view            : %.1f deg" % _peak_turn_deg(v_inert))
	print("    Neptune 'Galaxy' view                 : %.1f deg" % _peak_turn_deg(v_galaxy))
	print("    Neptune 'Real space' view (MODE_TRUE)  : %.1f deg" % _peak_turn_deg(v_true))
	var real := _peak_turn_deg(raw)
	var gal := _peak_turn_deg(v_galaxy)
	if gal > 2.0 * maxf(real, 1.0):
		print("KINK_TEST_VERDICT DISPLAY ARTIFACT — Galaxy view kinks (%.0f deg) far more than Neptune's real path (%.0f deg)" % [gal, real])
	else:
		print("KINK_TEST_VERDICT inconclusive — inspect the numbers")
	get_tree().quit(0)


func _peak_turn_deg(p: Array[Vector3]) -> float:
	var peak := 0.0
	for i in range(1, p.size() - 1):
		var a := p[i] - p[i - 1]
		var b := p[i + 1] - p[i]
		if a.length() > 1e-9 and b.length() > 1e-9:
			peak = maxf(peak, rad_to_deg(a.angle_to(b)))
	return peak


func _planet(sim: Simulation, n: String) -> SimBody:
	for b in sim.planets:
		if b.body_name == n:
			return b
	return null
