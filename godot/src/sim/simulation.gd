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
const MOON_TRAIL_MAX := 384              # moon trail buffer (tight coils, ~3 orbits)

# Resolving the fastest moons (Io: h ≈ 0.014 d) can demand thousands of
# substeps per frame at high time speeds — more than GDScript can integrate
# in a frame budget. Cap the work and let the clock lag behind instead
# (tick() already pushes unspent time back into sim_ms); lag_ratio reports
# the shortfall so the HUD can show a "physics-limited" badge.
# 120 keeps Year/s at full speed for planets-only (~61 substeps) and with
# the fast inner moons excluded (~107); with Io included, Year/s honestly
# runs at about a quarter speed instead of dropping frames.
const MAX_SUBSTEPS := 120
const H_MIN := 1e-4                      # days — a near-contact pair can't stall the budget

var sun: SimBody
var planets: Array = []      # SimBody, mutates when planets merge away
var moons: Array = []        # SimBody (simulated moons, catalog + user-added)
var customs: Array = []      # SimBody

var sim_ms: float = 0.0
var speed := 604800.0        # simulated seconds per real second (1 week/s)
var playing := true
var g_scale := 1.0

# Both moon flags are locked once physics starts: they change the body set,
# which the running integration can't absorb retroactively.
var moons_simulated := false
var sim_expensive_moons := true   # include Catalog.EXPENSIVE_MOONS (Io, Europa, Triton)
var lag_ratio := 1.0              # smoothed integrated/requested time per tick

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
	moons_simulated = Prefs.moons_default()
	_rebuild_moons()
	# trail reference frames: keep the focus body current and recompute the
	# cached trail vertices whenever the viewing frame changes (the raw
	# samples are frame-independent, so a switch never resets anything)
	TrailFrames.focus = sun
	Events.trail_mode_changed.connect(func(_m: int) -> void: _rebuild_trail_verts())
	Events.selection_changed.connect(_on_selection_for_trails)


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
	out.append_array(moons)
	out.append_array(customs)
	return out


## circular-orbit speed at d_au around `host` (the sun when null)
func circ_speed_kms(d_au: float, host: SimBody = null) -> float:
	var hm := 1.0 if host == null else mass_of(host)
	return 29.784 * sqrt(hm * g_scale / d_au)


## current mass in solar masses (live nb value in physics mode)
func mass_of(body: SimBody) -> float:
	if physics_active:
		var i := nb.index_of(body)
		if i >= 0:
			return nb.m[i]
	return base_mass_of(body) * body.mass_scale


# ================================================================
# Simulated moons: lifecycle
# ================================================================
func set_moons_simulated(on: bool) -> void:
	if physics_active or physics_permanent or moons_simulated == on:
		return
	moons_simulated = on
	_rebuild_moons()
	Events.moons_mode_changed.emit()


func set_expensive_moons(on: bool) -> void:
	if physics_active or physics_permanent or sim_expensive_moons == on:
		return
	sim_expensive_moons = on
	if moons_simulated:
		_rebuild_moons()
	Events.moons_mode_changed.emit()


## (re)create moon SimBodies from the catalog to match the current flags.
## Only reachable in Kepler mode, so no nb bookkeeping and no custom moons.
func _rebuild_moons() -> void:
	for mb in moons:
		Events.body_removed.emit(mb)
	moons.clear()
	if moons_simulated:
		for planet in planets:
			for idx in planet.moons.size():
				var md: Dictionary = planet.moons[idx]
				if not sim_expensive_moons and md.name in Catalog.EXPENSIVE_MOONS:
					continue
				var mb := make_moon_from_dict(planet.body_name, md, idx)
				mb.host = planet
				moons.append(mb)
				Events.body_added.emit(mb)
	Events.bodies_changed.emit()


## build a catalog-moon SimBody (host is set by the caller — the home planet
## normally, resolved by name when a snapshot restores a stolen moon)
func make_moon_from_dict(home_name: String, md: Dictionary, idx: int) -> SimBody:
	var b := SimBody.new()
	b.body_name = md.name
	b.color = Color(md.color)
	b.is_moon = true
	b.home_host_name = home_name
	b.size = md.size
	b.a_au = md.a_au
	b.incl_deg = md.get("incl", 3.0)
	b.phase0 = idx * 2.39996
	b.orbit_sign = -1.0 if md.period < 0.0 else 1.0
	b.mass_solar = md.mass
	b.disp_k = md.dist / md.a_au
	b.catalog_disp_k = b.disp_k
	b.radius_km = md.get("radius_km", 0.0)
	b.body_type = "Moon of %s" % home_name
	b.desc = "%s's moon, simulated live: its motion emerges from mutual gravity with every other body — it can even be stolen by a passing mass." % home_name
	b.period_days = MoonMath.derived_period_days(b.a_au, Catalog.PLANET_MASS.get(home_name, 3.0e-6), b.mass_solar, g_scale)
	# tidally locked: one rotation per orbit (sign follows the orbit)
	b.day_hours = b.period_days * 24.0 * b.orbit_sign
	b.init_trail(MOON_TRAIL_MAX, 0.24)
	b.trail_interval = b.period_days / 128.0
	return b


## the moon's home planet, if it still exists
func _planet_by_name(pname: String) -> SimBody:
	for b in planets:
		if b.body_name == pname:
			return b
	return null


func _has_custom_moons() -> bool:
	for mb in moons:
		if mb.custom:
			return true
	return false


## which of a planet's catalog moons should render as decorative kinematic
## pivots on its BodyView (the rest are simulated bodies with views of their own)
func decorative_moon_names(planet: SimBody) -> Array:
	var out: Array = []
	for md in planet.moons:
		if not moons_simulated or (not sim_expensive_moons and md.name in Catalog.EXPENSIVE_MOONS):
			out.append(md.name)
	return out


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
			sun.pos_au = Vector3.ZERO
			for i in range(1, nb.count()):
				var b: SimBody = nb.bodies[i]
				# stats stay sun-relative
				var rel_p := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0])
				var rel_v := Vector3(nb.vx[i] - nb.vx[0], nb.vy[i] - nb.vy[0], nb.vz[i] - nb.vz[0])
				b.r_au = rel_p.length()
				b.vel_kms = rel_v.length() * Units.KMS_PER_AUDAY
				b.pos_au = rel_p
				b.display_pos = nb.disp[i]
				if b.custom:
					# arrow shows on-screen (barycentric) motion
					b.vel_display = Vector3(nb.vx[i], nb.vy[i], nb.vz[i])
			_update_moon_hosts()
			_apply_moon_display(dt, SimTime.sim_days(sim_ms))
	else:
		for b: SimBody in planets:
			var pa := Kepler.body_position_au(b.el, T)
			var pv := Vector3(pa[0], pa[1], pa[2])
			b.r_au = pv.length()
			b.vel_kms = 29.784 * sqrt(maxf(2.0 / b.r_au - 1.0 / b.el.a[0], 0.0))   # vis-viva
			b.pos_au = pv
			b.display_pos = Units.to_display(pv)
			# advance the realtime trail; rebuild wholesale after a large time jump
			# (Kepler mode: the sun sits at the display origin, so the anchor is ZERO)
			var span := b.trail_max * b.trail_interval
			if days > b.trail_next_day + span or days < b.trail_next_day - span * 1.5:
				backfill_planet_trail(b)
			else:
				while days >= b.trail_next_day:
					var s := Kepler.body_position_au(b.el, SimTime.day_to_t(b.trail_next_day))
					b.trail_push(b.trail_next_day, Units.to_display(Vector3(s[0], s[1], s[2])),
							Vector3.ZERO, _focus_abs_kepler(b.trail_next_day))
					b.trail_next_day += b.trail_interval
		_tick_moons_kepler(days)


## Kepler-mode moons: analytic circles around their home planet, on exactly
## the state _seed_moons() will hand to the integrator — entering physics is
## seamless. Hosts never change here (stealing needs live gravity).
func _tick_moons_kepler(days: float) -> void:
	for mb: SimBody in moons:
		var host := mb.host
		if host == null:
			continue
		var om := _moon_omega(mb, Catalog.PLANET_MASS[host.body_name])
		var st := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * days, om)
		var rel := Vector3(st.p[0], st.p[1], st.p[2])
		mb.pos_au = host.pos_au + rel
		mb.display_pos = host.display_pos + rel * mb.disp_k
		mb.r_au = mb.pos_au.length()
		var hv := Kepler.state_vector(host.el, SimTime.day_to_t(days))
		mb.vel_kms = Vector3(hv.v[0] + st.v[0], hv.v[1] + st.v[1], hv.v[2] + st.v[2]).length() * Units.KMS_PER_AUDAY
		# trail: analytic samples on cadence, rebuilt after a large time jump.
		# Anchored on the host: local = amplified host-relative offset.
		var span := mb.trail_max * mb.trail_interval
		if days > mb.trail_next_day + span or days < mb.trail_next_day - span * 1.5:
			mb.trail_clear()
			mb.trail_next_day = days
		while days >= mb.trail_next_day:
			var day_s := mb.trail_next_day
			var hp := Kepler.body_position_au(host.el, SimTime.day_to_t(day_s))
			var ms := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * day_s, om)
			mb.trail_push(day_s, Vector3(ms.p[0], ms.p[1], ms.p[2]) * mb.disp_k,
					Units.to_display(Vector3(hp[0], hp[1], hp[2])), _focus_abs_kepler(day_s))
			mb.trail_next_day += mb.trail_interval


func _moon_omega(mb: SimBody, host_mass: float) -> float:
	return MoonMath.omega(mb.a_au, host_mass, mb.mass_solar, g_scale) * mb.orbit_sign


## analytic display position of a Kepler-mode moon at an arbitrary sim-day
func _moon_kepler_display(mb: SimBody, day: float, om: float) -> Vector3:
	var hp := Kepler.body_position_au(mb.host.el, SimTime.day_to_t(day))
	var st := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * day, om)
	return Units.to_display(Vector3(hp[0], hp[1], hp[2])) + Vector3(st.p[0], st.p[1], st.p[2]) * mb.disp_k


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
	for mb in moons:
		nb.add_body(mb, mb.mass_solar)
	physics_active = true
	_seed_planets()
	Events.mode_changed.emit()


func exit_physics() -> void:
	physics_active = false
	nb = null
	sun.display_pos = Vector3.ZERO
	sun.trail_clear()
	Events.mode_changed.emit()


## seed planets (then moons) from their Kepler state vectors at the current sim time
func _seed_planets() -> void:
	var T := SimTime.julian_centuries(sim_ms)
	nb.px[0] = 0.0; nb.py[0] = 0.0; nb.pz[0] = 0.0
	nb.vx[0] = 0.0; nb.vy[0] = 0.0; nb.vz[0] = 0.0
	for i in nb.count():
		var b: SimBody = nb.bodies[i]
		if b.is_sun or b.custom or b.is_moon:
			continue
		var s := Kepler.state_vector(b.el, T)
		nb.px[i] = s.p[0]; nb.py[i] = s.p[1]; nb.pz[i] = s.p[2]
		nb.vx[i] = s.v[0]; nb.vy[i] = s.v[1]; nb.vz[i] = s.v[2]
	_seed_moons()
	nb.zero_momentum()
	# start the display frame with the sun exactly at the origin (where the
	# Kepler ephemeris renders it) — the sun then wobbles away from there as
	# real forces act, instead of jumping at the handoff
	nb.frame_corr = nb.barycenter()
	nb.refresh_display(true)
	nb.compute_accel(g_scale)


## seed catalog moons on the same circles the Kepler-mode kinematics use, so
## the handoff to live gravity is seamless. User-added moons keep their state
## (they were injected at an arbitrary state vector, like customs).
func _seed_moons() -> void:
	var days := SimTime.sim_days(sim_ms)
	for mb: SimBody in moons:
		if mb.custom:
			continue
		var host := _planet_by_name(mb.home_host_name)
		if host == null:
			continue   # home planet merged away — keep the moon's live state
		var hi := nb.index_of(host)
		var mi := nb.index_of(mb)
		if hi < 0 or mi < 0:
			continue
		var om := _moon_omega(mb, nb.m[hi])
		var st := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * days, om)
		nb.px[mi] = nb.px[hi] + st.p[0]
		nb.py[mi] = nb.py[hi] + st.p[1]
		nb.pz[mi] = nb.pz[hi] + st.p[2]
		nb.vx[mi] = nb.vx[hi] + st.v[0]
		nb.vy[mi] = nb.vy[hi] + st.v[1]
		nb.vz[mi] = nb.vz[hi] + st.v[2]
		mb.host = host
		mb.host_prev = null
		mb.disp_k = mb.catalog_disp_k if mb.catalog_disp_k > 0.0 else mb.disp_k
		mb.bind_t = 1.0
		mb.trail_clear()


# ================================================================
# Moon host binding (capture / escape / stealing) + display mapping
# ================================================================
## Hill-sphere binding with hysteresis: a moon lets go of its host beyond
## 1.0 R_H and binds to the nearest planet/custom it sits within 0.6 R_H of.
## The gap keeps the binding from flapping at the boundary.
func _update_moon_hosts() -> void:
	for mb: SimBody in moons:
		var mi := nb.index_of(mb)
		if mi < 0:
			continue
		if mb.host != null:
			var hi := nb.index_of(mb.host)
			if hi < 0:
				_set_host(mb, null)   # host merged away
			elif nb.real_distance(mi, hi) > MoonMath.hill_radius_au(nb.real_distance(hi, 0), nb.m[hi], nb.m[0]):
				_set_host(mb, null)
		var best: SimBody = null
		var best_i := -1
		var best_r := INF
		for ci in range(1, nb.count()):
			var c: SimBody = nb.bodies[ci]
			if c.is_moon:
				continue
			var r := nb.real_distance(mi, ci)
			if r < best_r:
				best_r = r
				best = c
				best_i = ci
		if best != null and best != mb.host:
			if best_r < 0.6 * MoonMath.hill_radius_au(nb.real_distance(best_i, 0), nb.m[best_i], nb.m[0]):
				_set_host(mb, best)


func _set_host(mb: SimBody, new_host: SimBody) -> void:
	if mb.host == new_host:
		return
	var old := mb.host
	mb.host_prev = old
	mb.disp_k_prev = mb.disp_k
	mb.host = new_host
	mb.bind_t = 0.0   # display blends from the old regime over ~1.2 s
	# trail samples are anchored on the host — a host change rebases the
	# frame, so the old history can't be carried across
	mb.trail_clear()
	mb.trail_next_day = SimTime.sim_days(sim_ms)
	if new_host != null:
		if new_host.body_name == mb.home_host_name and mb.catalog_disp_k > 0.0:
			mb.disp_k = mb.catalog_disp_k   # back home: original look
		else:
			var r := nb.real_distance(nb.index_of(mb), nb.index_of(new_host))
			mb.disp_k = MoonMath.capture_disp_k(new_host.size, mb.size, r)
	# a displaced catalog moon can't be reproduced by the ephemeris — never
	# fall back. (A custom moon wandering off doesn't lock anything: removing
	# it restores the original system.)
	if not mb.custom:
		physics_permanent = true
	if new_host == null:
		Events.toast_requested.emit("%s escaped %s" % [mb.body_name, old.body_name if old != null else "its orbit"])
	else:
		Events.toast_requested.emit("%s captured by %s" % [mb.body_name, new_host.body_name])
	Events.bodies_changed.emit()   # rail regroups under the new host


## Second display pass (after every body's display_pos is set): bound moons
## render at host + real offset × disp_k — physics runs at true scale, the
## screen shows the catalog's exaggerated orbit. Free moons use the standard
## heliocentric mapping. Host changes blend between the two regimes.
func _apply_moon_display(dt: float, day: float) -> void:
	for mb: SimBody in moons:
		var mi := nb.index_of(mb)
		if mi < 0:
			continue
		var helio := nb.disp[mi]
		var target := _moon_mapped(mb, mb.host, mb.disp_k, mi, helio)
		if mb.bind_t < 1.0:
			mb.bind_t = minf(mb.bind_t + dt / 1.2, 1.0)
			var from := _moon_mapped(mb, mb.host_prev, mb.disp_k_prev, mi, helio)
			mb.display_pos = from.lerp(target, smoothstep(0.0, 1.0, mb.bind_t))
			if mb.bind_t >= 1.0:
				mb.host_prev = null
		else:
			mb.display_pos = target
		# a bound moon's meaningful velocity is host-relative — the raw
		# barycentric vector is dominated by the host's own orbital motion
		# and would draw an arrow that dwarfs the whole moon system
		if mb.custom and mb.host != null:
			var hi := nb.index_of(mb.host)
			if hi >= 0:
				mb.vel_display = Vector3(nb.vx[mi] - nb.vx[hi], nb.vy[mi] - nb.vy[hi], nb.vz[mi] - nb.vz[hi])
		# trails advance here (once per frame), not per substep — a bound
		# moon's path only exists in this amplified display space. Anchored
		# on the host (the sun while free-flying).
		if day >= mb.trail_next_day:
			var anchor := sun.display_pos
			if mb.host != null:
				anchor = mb.host.display_pos
			var fa := Vector3.ZERO
			if TrailFrames.mode == TrailFrames.MODE_FOCUS and TrailFrames.focus != null:
				fa = TrailFrames.focus.display_pos
			mb.trail_push(day, mb.display_pos - anchor, anchor, fa)
			mb.trail_next_day = day + mb.trail_interval


func _moon_mapped(mb: SimBody, host: SimBody, k: float, mi: int, helio: Vector3) -> Vector3:
	if host == null:
		return helio
	var hi := nb.index_of(host)
	if hi < 0:
		return helio
	var rel := Vector3(nb.px[mi] - nb.px[hi], nb.py[mi] - nb.py[hi], nb.pz[mi] - nb.pz[hi])
	return host.display_pos + rel * k


func _step_physics(dt_days: float, end_day: float) -> void:
	var day := end_day - dt_days
	var remaining := dt_days
	var steps := 0
	while remaining > 1e-9:
		steps += 1
		if steps > MAX_SUBSTEPS:
			break
		# adaptive step: 0.1 d normally, but during close encounters (and for
		# fast moons like Io) shrink to ~1/20 of the tightest pair's dynamical
		# timescale so the motion is integrated instead of blasted through.
		# H_MIN keeps a near-contact pair from stalling the whole budget —
		# below that scale the merge rule resolves the encounter anyway.
		var h := minf(clampf(nb.tau_min / 20.0, H_MIN, 0.1), remaining)
		nb.leapfrog_substep(h, g_scale)
		day += h
		remaining -= h

		# barycentric display positions per substep — drive trails & collisions
		nb.refresh_display(false)

		# collisions: closest approach over each substep's motion segment,
		# so fast bodies can't tunnel through each other between steps.
		# Bodies merge when their rendered meshes substantially overlap.
		# Bound moons render at host + real offset × disp_k, so their raw
		# display position sits INSIDE the host's exaggerated sphere — test
		# those pairs in real space, scaled back into moon display units.
		var merged := false
		for i in range(nb.count() - 1):
			if merged:
				break
			for j in range(i + 1, nb.count()):
				var a: SimBody = nb.bodies[i]
				var b: SimBody = nb.bodies[j]
				var bound_k := 0.0
				if a.is_moon and a.host != null:
					bound_k = a.disp_k
				if b.is_moon and b.host != null:
					bound_k = maxf(bound_k, b.disp_k)
				var hit: bool
				if bound_k > 0.0:
					hit = nb.real_distance(i, j) * bound_k < 0.75 * (a.size + b.size)
				else:
					hit = nb.swept_distance(i, j) < 0.75 * (a.size + b.size)
				if hit:
					_merge_bodies(i, j)
					merged = true
					break

		# trails: sample on cadence, or sooner whenever the velocity direction
		# has swung > 4° since the last sample — sharp encounters stay smooth.
		# (Moons are skipped: their display space is amplified per-host, so
		# their trails advance once per frame in _apply_moon_display.)
		# Samples are sun-anchored: local = heliocentric display offset,
		# anchor = the sun's absolute display position this substep.
		var focus_abs := Vector3.ZERO
		if TrailFrames.mode == TrailFrames.MODE_FOCUS and TrailFrames.focus != null:
			var fi := nb.index_of(TrailFrames.focus)
			focus_abs = nb.disp[fi] if fi >= 0 else TrailFrames.focus.display_pos
		for i in nb.count():
			var b: SimBody = nb.bodies[i]
			if b.is_moon:
				continue
			var need := day >= b.trail_next_day
			if not need and b.trail_lv_ok:
				var vm := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
				if vm > 1e-12 and (nb.vx[i] * b.trail_lv.x + nb.vy[i] * b.trail_lv.y + nb.vz[i] * b.trail_lv.z) / vm < COS_TRAIL:
					need = true
			if need:
				b.trail_push(day, nb.disp[i] - nb.disp[0], nb.disp[0], focus_abs)
				var vm2 := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
				if vm2 == 0.0:
					vm2 = 1.0
				b.trail_lv = Vector3(nb.vx[i] / vm2, nb.vy[i] / vm2, nb.vz[i] / vm2)
				b.trail_lv_ok = true
				var r_sun := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0]).length()
				b.trail_interval = _trail_interval(b, r_sun)
				b.trail_next_day = day + b.trail_interval
	# hit the substep budget: let the clock wait for the physics rather than
	# corrupt the integration. lag_ratio feeds the HUD "physics-limited" badge.
	lag_ratio = lag_ratio * 0.9 + 0.1 * (1.0 if dt_days <= 0.0 else (dt_days - remaining) / dt_days)
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
	if lb.is_moon:
		remove_moon(lb, false)
	elif lb.custom:
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
## cfg: { name, mass_e, dist_au, lon_deg, lat_deg, speed_kms, dir_deg, host? }
## With a host SimBody the placement is host-relative (a new moon around a
## planet); otherwise sun-relative as before.
func add_custom_body(cfg: Dictionary) -> SimBody:
	enter_physics()
	var host: SimBody = cfg.get("host", null)
	custom_count += 1
	var palette_idx := custom_count % Catalog.CUSTOM_PALETTES.size()
	var palette: Dictionary = Catalog.CUSTOM_PALETTES[palette_idx]
	var massive: bool = host == null and cfg.mass_e >= 20000.0   # ~0.06 solar masses → treat as a star
	var size: float
	if host != null:
		size = clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.12, 1.2)   # moon-scale
	else:
		size = clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.35, 3.4)

	var body := SimBody.new()
	body.body_name = cfg.name if cfg.name != "" else "Body %d" % custom_count
	body.color = Color("ffc46b") if massive else Color(palette.color)
	body.custom = true
	body.is_star = massive
	body.mass_e = cfg.mass_e
	body.size = size
	body.tilt = 0.0
	body.day_hours = 24.0
	body.radius_km = 0.0
	body.period_days = 0.0
	body.tex = { kind = "custom", palette_index = palette_idx }
	if host != null:
		body.is_moon = true
		body.host = host
		body.home_host_name = host.body_name
		body.a_au = cfg.dist_au
		body.mass_solar = cfg.mass_e * Units.EARTH_SOLAR
		body.disp_k = MoonMath.add_disp_k(host.size, cfg.dist_au)
		body.body_type = "Custom moon of %s" % host.body_name
		body.desc = "User-defined moon: %s Earth masses, injected %s AU from %s moving %s km/s. Its path is computed live from mutual gravity with every other body." % [cfg.mass_e, cfg.dist_au, host.body_name, cfg.speed_kms]
		body.period_days = MoonMath.derived_period_days(cfg.dist_au, mass_of(host), body.mass_solar, g_scale)
		body.init_trail(MOON_TRAIL_MAX, 0.5)
		body.trail_interval = body.period_days / 128.0
	else:
		body.body_type = "Custom star" if massive else "Custom body"
		body.desc = "User-defined body: %s Earth masses, injected at %s AU moving %s km/s. Its path is computed live from mutual gravity with every other body." % [cfg.mass_e, cfg.dist_au, cfg.speed_kms]
		# breadcrumb trail — the orbit this body actually traces out
		body.init_trail(TRAIL_MAX, 0.5)

	var bary_before := nb.barycenter()
	var st := NBodySystem.state_vector_from_inputs(cfg)
	var idx := nb.add_body(body, cfg.mass_e * Units.EARTH_SOLAR)
	# anchor the relative state to the host's row (the sun by default)
	var ai := 0
	if host != null:
		ai = maxi(nb.index_of(host), 0)
	nb.px[idx] = st.p[0] + nb.px[ai]
	nb.py[idx] = st.p[1] + nb.py[ai]
	nb.pz[idx] = st.p[2] + nb.pz[ai]
	nb.vx[idx] = st.v[0] + nb.vx[ai]
	nb.vy[idx] = st.v[1] + nb.vy[ai]
	nb.vz[idx] = st.v[2] + nb.vz[ai]
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

	if host != null:
		moons.append(body)
	else:
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
	if customs.is_empty() and not _has_custom_moons() and not physics_permanent:
		exit_physics()


## removes a moon (user-deleted custom moon, or a merge loser)
func remove_moon(body: SimBody, preserve_frame: bool = true) -> void:
	moons.erase(body)
	_remove_from_system(body, preserve_frame)
	if physics_active and customs.is_empty() and not _has_custom_moons() and not physics_permanent:
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
	if body.is_moon:
		return body.mass_solar
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
		# re-seed planets + catalog moons from the ephemeris; custom bodies
		# (and custom moons) keep their state
		_seed_planets()
		for b in planets:
			backfill_planet_trail(b)
		for b in customs:
			b.trail_clear()   # their old path no longer connects — start fresh
		for b in moons:
			if b.custom:
				b.trail_clear()
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


## rebuild a planet's full trail analytically (Kepler mode, or right after
## re-seeding — in both cases the sun sits at the display origin, so the
## anchor is ZERO throughout)
func backfill_planet_trail(b: SimBody) -> void:
	b.trail_clear()
	var day := SimTime.sim_days(sim_ms)
	for k in range(b.trail_max - 1, -1, -1):
		var day_s := day - k * b.trail_interval
		var s := Kepler.body_position_au(b.el, SimTime.day_to_t(day_s))
		b.trail_push(day_s, Units.to_display(Vector3(s[0], s[1], s[2])),
				Vector3.ZERO, _focus_abs_kepler(day_s))
	b.trail_next_day = day + b.trail_interval


## The focus body's absolute display position at an arbitrary sim-day,
## computed from the ephemeris — used by Kepler-mode pushes and backfills
## (physics-mode pushes read the live integrator state instead). Returns
## ZERO unless the FOCUS frame is active, so non-focus modes pay nothing.
func _focus_abs_kepler(day: float) -> Vector3:
	if TrailFrames.mode != TrailFrames.MODE_FOCUS:
		return Vector3.ZERO
	var f := TrailFrames.focus
	if f == null or f.is_sun:
		return Vector3.ZERO
	if f.is_moon:
		if f.host != null and not f.custom:
			return _moon_kepler_display(f, day, _moon_omega(f, Catalog.PLANET_MASS[f.host.body_name]))
		return f.display_pos
	if f.custom:
		return f.display_pos   # no ephemeris — best effort
	var s := Kepler.body_position_au(f.el, SimTime.day_to_t(day))
	return Units.to_display(Vector3(s[0], s[1], s[2]))


## selection drives the FOCUS frame's reference body (falls back to the sun)
func _on_selection_for_trails(body) -> void:
	var f: SimBody = body if body != null else sun
	if TrailFrames.focus == f:
		return
	TrailFrames.focus = f
	if TrailFrames.mode == TrailFrames.MODE_FOCUS:
		_rebuild_trail_verts()


## frame mode or focus changed: recompute every cached vertex from the
## frame-independent samples — nothing is cleared, switching is lossless
func _rebuild_trail_verts() -> void:
	for b in all_bodies():
		b.trail_rebuild()
