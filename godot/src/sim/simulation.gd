class_name Simulation
extends Node
## Orchestrates the whole simulation: owns the clock, switches between the
## Kepler ephemeris and live N-body gravity, seeds/steps the integrator,
## resolves mergers, and maintains every body's trail. Views/UI read SimBody
## state; discrete events go out through the Events autoload.
##
## When the user injects a body (or edits masses / G), every position from
## then on comes from the leapfrog integrator — planets are seeded with their
## true Kepler state vectors, so orbits continue seamlessly and then respond
## to the newcomer's gravity.

const COS_TRAIL := 0.99756405025982420   # cos(4°) — trail resample threshold
const TRAIL_MAX := 1400                  # custom-body trail buffer

var sun: SimBody
var planets: Array = []      # SimBody, mutates when planets merge away
var customs: Array = []      # SimBody

var sim_ms: float = 0.0
var speed := 604800.0        # simulated seconds per real second (1 week/s)
var playing := true
var g_scale := 1.0

var physics_active := false
# `physics_permanent` is set after any merger / mass edit / G change — the
# Kepler ephemeris can no longer describe the altered system, so we never
# fall back to it.
var physics_permanent := false
var nb: NBodySystem = null
var custom_count := 0


func _init() -> void:
	sim_ms = Time.get_unix_time_from_system() * 1000.0
	var sun_def := Catalog.make_sun()
	sun = SimBody.from_def(sun_def)
	sun.is_sun = true
	# the sun wobbles around the barycenter in N-body mode — trail it too
	sun.init_trail(1600, 0.3)
	for def in Catalog.make_planets():
		planets.append(make_planet_from_def(def))


## build a planet SimBody with its trail configured (also used when a saved
## snapshot restores a merged-away planet)
func make_planet_from_def(def: BodyDef) -> SimBody:
	var b := SimBody.from_def(def)
	# realtime orbit trail — the path this body actually travels
	# (backfilled from the ephemeris on first tick, extended live each frame)
	b.init_trail(1024, 0.24)
	b.trail_interval = b.period_days / 512.0   # 512 samples per orbit, buffer holds ~2 orbits
	return b


func all_bodies() -> Array:
	var out: Array = [sun]
	out.append_array(planets)
	out.append_array(customs)
	return out


func circ_speed_kms(d_au: float) -> float:
	return 29.784 * sqrt(g_scale / d_au)


# ================================================================
# Per-frame update
# ================================================================
func tick(dt: float) -> void:
	if playing:
		sim_ms += dt * speed * 1000.0
	var T := SimTime.julian_centuries(sim_ms)
	var days := SimTime.sim_days(sim_ms)

	# positions: N-body gravity when active, otherwise Kepler ephemeris
	if physics_active:
		if playing and dt > 0.0:
			_step_physics(dt * speed / 86400.0, days)
		if physics_active:              # a merge may have absorbed the last custom body
			nb.refresh_display(true)    # barycentric frame; the sun itself wobbles
			sun.display_pos = nb.disp[0]
			for i in range(1, nb.count()):
				var b: SimBody = nb.bodies[i]
				# stats stay sun-relative
				var rel_p := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0])
				var rel_v := Vector3(nb.vx[i] - nb.vx[0], nb.vy[i] - nb.vy[0], nb.vz[i] - nb.vz[0])
				b.r_au = rel_p.length()
				b.vel_kms = rel_v.length() * Units.KMS_PER_AUDAY
				b.display_pos = nb.disp[i]
				if b.custom:
					# arrow shows on-screen (barycentric) motion
					b.vel_display = Vector3(nb.vx[i], nb.vy[i], nb.vz[i])
	else:
		for b: SimBody in planets:
			var pa := Kepler.body_position_au(b.el, T)
			var pv := Vector3(pa[0], pa[1], pa[2])
			b.r_au = pv.length()
			b.vel_kms = 29.784 * sqrt(maxf(2.0 / b.r_au - 1.0 / b.el.a[0], 0.0))   # vis-viva
			b.display_pos = Units.to_display(pv)
			# advance the realtime trail; rebuild wholesale after a large time jump
			var span := b.trail_max * b.trail_interval
			if days > b.trail_next_day + span or days < b.trail_next_day - span * 1.5:
				backfill_planet_trail(b)
			else:
				while days >= b.trail_next_day:
					var s := Kepler.body_position_au(b.el, SimTime.day_to_t(b.trail_next_day))
					b.trail_push(Units.to_display(Vector3(s[0], s[1], s[2])))
					b.trail_next_day += b.trail_interval


# ================================================================
# N-body mode
# ================================================================
func enter_physics() -> void:
	if physics_active:
		return
	nb = NBodySystem.new()
	nb.add_body(sun, 1.0)
	for b in planets:
		nb.add_body(b, Catalog.PLANET_MASS[b.body_name])
	physics_active = true
	_seed_planets()
	Events.mode_changed.emit()


func exit_physics() -> void:
	physics_active = false
	nb = null
	sun.display_pos = Vector3.ZERO
	sun.trail_clear()
	Events.mode_changed.emit()


## seed planets from their Kepler state vectors at the current sim time
func _seed_planets() -> void:
	var T := SimTime.julian_centuries(sim_ms)
	nb.px[0] = 0.0; nb.py[0] = 0.0; nb.pz[0] = 0.0
	nb.vx[0] = 0.0; nb.vy[0] = 0.0; nb.vz[0] = 0.0
	for i in nb.count():
		var b: SimBody = nb.bodies[i]
		if b.is_sun or b.custom:
			continue
		var s := Kepler.state_vector(b.el, T)
		nb.px[i] = s.p[0]; nb.py[i] = s.p[1]; nb.pz[i] = s.p[2]
		nb.vx[i] = s.v[0]; nb.vy[i] = s.v[1]; nb.vz[i] = s.v[2]
	nb.zero_momentum()
	nb.refresh_display(true)
	nb.compute_accel(g_scale)


func _step_physics(dt_days: float, end_day: float) -> void:
	var day := end_day - dt_days
	var remaining := dt_days
	var guard := 0
	while remaining > 1e-9:
		guard += 1
		if guard > 6000:
			break
		# adaptive step: 0.1 d normally, but during close encounters shrink to
		# ~1/20 of the tightest pair's dynamical timescale so the swing-by is
		# integrated instead of blasted through (that momentum "yank" was the
		# symptom of under-resolving these passes)
		var h := minf(minf(0.1, nb.tau_min / 20.0), remaining)
		nb.leapfrog_substep(h, g_scale)
		day += h
		remaining -= h

		# barycentric display positions per substep — drive trails & collisions
		nb.refresh_display(false)

		# collisions: closest approach over each substep's motion segment,
		# so fast bodies can't tunnel through each other between steps.
		# Bodies merge when their rendered meshes substantially overlap.
		var merged := false
		for i in range(nb.count() - 1):
			if merged:
				break
			for j in range(i + 1, nb.count()):
				var a: SimBody = nb.bodies[i]
				var b: SimBody = nb.bodies[j]
				if nb.swept_distance(i, j) < 0.75 * (a.size + b.size):
					_merge_bodies(i, j)
					merged = true
					break

		# trails: sample on cadence, or sooner whenever the velocity direction
		# has swung > 4° since the last sample — sharp encounters stay smooth
		for i in nb.count():
			var b: SimBody = nb.bodies[i]
			var need := day >= b.trail_next_day
			if not need and b.trail_lv_ok:
				var vm := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
				if vm > 1e-12 and (nb.vx[i] * b.trail_lv.x + nb.vy[i] * b.trail_lv.y + nb.vz[i] * b.trail_lv.z) / vm < COS_TRAIL:
					need = true
			if need:
				b.trail_push(nb.disp[i])
				var vm2 := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
				if vm2 == 0.0:
					vm2 = 1.0
				b.trail_lv = Vector3(nb.vx[i] / vm2, nb.vy[i] / vm2, nb.vz[i] / vm2)
				b.trail_lv_ok = true
				var r_sun := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0]).length()
				b.trail_interval = _trail_interval(b, r_sun)
				b.trail_next_day = day + b.trail_interval
	# hit the substep budget mid-encounter: let the clock wait for the physics
	# rather than corrupt the integration
	if remaining > 1e-9:
		sim_ms -= remaining * 86400000.0


## The sun always survives; otherwise the heavier body does, growing by
## combined volume.
func _merge_bodies(i: int, j: int) -> void:
	var si := i
	var li := j
	if i != 0 and nb.m[j] > nb.m[i]:
		si = j
		li = i
	var sb: SimBody = nb.bodies[si]
	var lb: SimBody = nb.bodies[li]
	var merged_m := nb.m[si] + nb.m[li]
	nb.merge_parts(si, li)
	physics_permanent = true

	# impact flash + debris at the point of collision — nb.disp[li] is still
	# valid here (merge_parts only touched the survivor's row, and refresh_display
	# already ran for this substep), and matches the sun-anchored display frame
	var impact := nb.disp[li]
	var effect_scale := maxf(lb.size if sb.is_sun else sb.size, 0.8)

	sb.mass_scale = 1.0    # merged mass becomes the new 1× baseline
	if not sb.is_sun:
		var new_size := minf(pow(pow(sb.size, 3.0) + pow(lb.size, 3.0), 1.0 / 3.0), 4.2)
		sb.size = new_size
		if sb.custom:
			sb.mass_e = roundf((merged_m / Units.EARTH_SOLAR) * 100.0) / 100.0
	Events.merged.emit(sb, lb.body_name, impact, lb.color, effect_scale)
	Events.toast_requested.emit("%s merged into %s" % [lb.body_name, sb.body_name])

	var loser_selected: bool = Events.selected == lb
	var survivor_selected: bool = Events.selected == sb
	if lb.custom:
		# merges conserve mass (merge_parts already folded it into the
		# survivor), so the barycenter doesn't jump — don't double-correct
		remove_custom_body(lb, false)
	else:
		_remove_planet(lb)
	if loser_selected or survivor_selected:
		Events.select_requested.emit(sb)   # follow / refresh the survivor
	nb.compute_accel(g_scale)


# ================================================================
# Custom bodies
# ================================================================
## cfg: { name, mass_e, dist_au, lon_deg, lat_deg, speed_kms, dir_deg }
func add_custom_body(cfg: Dictionary) -> SimBody:
	enter_physics()
	custom_count += 1
	var palette_idx := custom_count % Catalog.CUSTOM_PALETTES.size()
	var palette: Dictionary = Catalog.CUSTOM_PALETTES[palette_idx]
	var massive: bool = cfg.mass_e >= 20000.0   # ~0.06 solar masses → treat as a star
	var size := clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.35, 3.4)

	var body := SimBody.new()
	body.body_name = cfg.name if cfg.name != "" else "Body %d" % custom_count
	body.color = Color("ffc46b") if massive else Color(palette.color)
	body.custom = true
	body.is_star = massive
	body.mass_e = cfg.mass_e
	body.size = size
	body.body_type = "Custom star" if massive else "Custom body"
	body.desc = "User-defined body: %s Earth masses, injected at %s AU moving %s km/s. Its path is computed live from mutual gravity with every other body." % [cfg.mass_e, cfg.dist_au, cfg.speed_kms]
	body.tilt = 0.0
	body.day_hours = 24.0
	body.radius_km = 0.0
	body.period_days = 0.0
	body.tex = { kind = "custom", palette_index = palette_idx }
	# breadcrumb trail — the orbit this body actually traces out
	body.init_trail(TRAIL_MAX, 0.5)

	var bary_before := nb.barycenter()
	var st := NBodySystem.state_vector_from_inputs(cfg)
	var idx := nb.add_body(body, cfg.mass_e * Units.EARTH_SOLAR)
	nb.px[idx] = st.p[0] + nb.px[0]
	nb.py[idx] = st.p[1] + nb.py[0]
	nb.pz[idx] = st.p[2] + nb.pz[0]
	nb.vx[idx] = st.v[0] + nb.vx[0]
	nb.vy[idx] = st.v[1] + nb.vy[0]
	nb.vz[idx] = st.v[2] + nb.vz[0]
	nb.zero_momentum()
	# the new body's mass shifts the barycenter used for display — absorb
	# that jump so every already-visible body stays exactly where it was
	nb.absorb_frame_shift(bary_before)
	nb.refresh_display(true)
	nb.compute_accel(g_scale)
	body.display_pos = nb.disp[idx]
	body.r_au = Vector3(nb.px[idx] - nb.px[0], nb.py[idx] - nb.py[0], nb.pz[idx] - nb.pz[0]).length()
	body.vel_kms = Vector3(nb.vx[idx] - nb.vx[0], nb.vy[idx] - nb.vy[0], nb.vz[idx] - nb.vz[0]).length() * Units.KMS_PER_AUDAY
	body.vel_display = Vector3(nb.vx[idx], nb.vy[idx], nb.vz[idx])

	customs.append(body)
	Events.body_added.emit(body)
	Events.bodies_changed.emit()
	Events.select_requested.emit(body)
	return body


## preserve_frame: true for a genuine deletion (mass vanishes, so the
## barycenter jumps and must be absorbed); false when the body's mass has
## already been folded into a merge survivor, so there's no jump to correct.
func remove_custom_body(body: SimBody, preserve_frame: bool = true) -> void:
	# erase before signalling — bodies_changed listeners rebuild from customs
	customs.erase(body)
	_remove_from_system(body, preserve_frame)
	# planets snap back to the ephemeris — unless a merger has altered the system
	if customs.is_empty() and not physics_permanent:
		exit_physics()


func _remove_planet(body: SimBody) -> void:
	planets.erase(body)
	_remove_from_system(body, false)


func _remove_from_system(body: SimBody, preserve_frame: bool) -> void:
	var pi := nb.index_of(body) if nb != null else -1
	if pi >= 0:
		var bary_before := nb.barycenter() if preserve_frame else Vector3.ZERO
		nb.remove_at(pi)
		if preserve_frame:
			nb.absorb_frame_shift(bary_before)
	Events.body_removed.emit(body)
	Events.bodies_changed.emit()


# ================================================================
# Live editing & time controls
# ================================================================
func set_mass_scale(body: SimBody, mult: float) -> void:
	enter_physics()   # masses only matter to the N-body engine
	body.mass_scale = mult
	var i := nb.index_of(body)
	if i >= 0:
		nb.m[i] = nb.base_m[i] * mult
		if body.custom:
			body.mass_e = roundf((nb.m[i] / Units.EARTH_SOLAR) * 100.0) / 100.0
	if absf(mult - 1.0) > 0.001:
		physics_permanent = true   # the timeline has diverged
	nb.compute_accel(g_scale)


func base_mass_of(body: SimBody) -> float:
	if physics_active:
		var i := nb.index_of(body)
		if i >= 0:
			return nb.base_m[i]
	if body.is_sun:
		return 1.0
	if body.custom:
		return body.mass_e * Units.EARTH_SOLAR
	return Catalog.PLANET_MASS[body.body_name]


func set_g_scale(g: float) -> void:
	g_scale = g
	if absf(g_scale - 1.0) > 0.005:
		enter_physics()   # the ephemeris assumes real gravity
		physics_permanent = true
	if physics_active:
		nb.compute_accel(g_scale)
	Events.mode_changed.emit()


## Reset simulation to the current date.
func reset_now() -> void:
	sim_ms = Time.get_unix_time_from_system() * 1000.0
	if physics_active:
		_seed_planets()   # re-seed planets from the ephemeris; custom bodies keep their state
		for b in planets:
			backfill_planet_trail(b)
		for b in customs:
			b.trail_clear()   # their old path no longer connects — start fresh
		sun.trail_clear()


# ================================================================
# Trails
# ================================================================
## sim-days between trail samples; customs adapt to their current distance
## (denser sampling when close to the sun, where the path curves fastest)
func _trail_interval(b: SimBody, r_au: float) -> float:
	if b.is_sun:
		return 15.0   # the sun drifts slowly; angle-trigger catches the rest
	if not b.custom:
		return b.period_days / 512.0
	return maxf(365.25 * pow(maxf(r_au, 0.05), 1.5) / (512.0 * sqrt(g_scale)), 0.02)


## rebuild a planet's full trail analytically (Kepler mode, or right after re-seeding)
func backfill_planet_trail(b: SimBody) -> void:
	b.trail_clear()
	var day := SimTime.sim_days(sim_ms)
	for k in range(b.trail_max - 1, -1, -1):
		var s := Kepler.body_position_au(b.el, SimTime.day_to_t(day - k * b.trail_interval))
		b.trail_push(Units.to_display(Vector3(s[0], s[1], s[2])))
	b.trail_next_day = day + b.trail_interval
