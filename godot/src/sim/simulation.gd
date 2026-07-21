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
# The compiled kernel is ~40x faster per block, so the wall-time protection can
# be far higher without risking a frame hang — this is what actually lifts the
# top time-speed (Year/s and beyond) once the kernel is doing the integration.
# ~1200 work ≈ a couple of ms/frame at native speed.
const MAX_SUBSTEPS_NATIVE := 1200
const H_MIN := 1e-4                      # days — a near-contact pair can't stall the budget

# Block time-stepping: fast moons subcycle inside a 0.1-day block instead of
# forcing tiny steps on the whole system (NBodySystem.step_block). A single
# fast moon no longer collapses the global step. Set false to fall back to the
# original global-substep integrator (kept as the k==1 fast path anyway).
const USE_BLOCK := true
# Route the per-frame block loop through the compiled kernel when one is
# available (NBodyNative on desktop/Android, WASM on web); falls back to the
# GDScript path automatically. Set false to force the pure-GDScript integrator.
const USE_NATIVE := true
# Block size cap as a fraction of the tightest pair's dynamical time: with
# K_MAX/SAFETY = 8/20, H ≤ 0.4·tau_min guarantees the tightest body resolves at
# the deepest rung (h = tau_min/20, the old global step's finest resolution).
const H_TAU_FRAC := 0.4

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

# Last _step_physics breakdown for the perf panel / tests: substeps taken,
# pair-force evaluations, µs per phase, last substep size. Refilled every
# physics tick; stale (or empty) outside physics.
var perf := {}

var physics_active := false
# `physics_permanent` is set after any merger / mass edit / G change — the
# Kepler ephemeris can no longer describe the altered system, so we never
# fall back to it.
var physics_permanent := false
var nb: NBodySystem = null
var custom_count := 0

# Compiled-kernel backend (created lazily; null-safe — ready() gates use).
var _kernel: NativeKernel = null


func _init() -> void:
	if USE_NATIVE:
		_kernel = NativeKernel.new()   # detects backend; web loads its module async
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
	TrailFrames.sun_body = sun
	Events.trail_mode_changed.connect(func(_m: int) -> void: _rebuild_trail_verts())
	# real-scale / moon-frame toggles re-render every trail from raw samples —
	# lossless in both directions, exactly like a frame-mode switch
	Events.real_scale_changed.connect(func(_on: bool) -> void: _rebuild_trail_verts())
	Events.moon_trail_frame_changed.connect(func(_on: bool) -> void: _rebuild_trail_verts())
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


## (re)create CATALOG moon SimBodies to match the current flags. Only
## reachable in Kepler mode (no nb bookkeeping). User-added moons and railed
## bodies aren't the catalog's to rebuild — they're kept as-is.
func _rebuild_moons() -> void:
	var kept: Array = []
	for mb: SimBody in moons:
		if mb.custom or not mb.simulated:
			kept.append(mb)
		else:
			Events.body_removed.emit(mb)
	moons = kept
	if moons_simulated:
		for planet in planets:
			for idx in planet.moons.size():
				var md: Dictionary = planet.moons[idx]
				if not sim_expensive_moons and md.name in Catalog.EXPENSIVE_MOONS:
					continue
				if _live_catalog_moon(planet.body_name, md.name) != null:
					continue   # survived as a railed body — don't duplicate
				var mb := make_moon_from_dict(planet.body_name, md, idx)
				mb.host = planet
				moons.append(mb)
				Events.body_added.emit(mb)
	Events.bodies_changed.emit()


## the live SimBody for a catalog moon, if one exists (simulated or railed)
func _live_catalog_moon(home: String, mname: String) -> SimBody:
	for mb: SimBody in moons:
		if not mb.custom and mb.home_host_name == home and mb.body_name == mname:
			return mb
	return null


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


## live gravity is only needed while at least one user-added body is actually
## being integrated — railed bodies are kinematic and don't hold physics open
func _has_simulated_customs() -> bool:
	for b: SimBody in customs:
		if b.simulated:
			return true
	return false


func _has_simulated_custom_moons() -> bool:
	for mb: SimBody in moons:
		if mb.custom and mb.simulated:
			return true
	return false


## which of a planet's catalog moons should render as decorative kinematic
## pivots on its BodyView — the ones with no live SimBody of their own
## (simulated or railed bodies have real views)
func decorative_moon_names(planet: SimBody) -> Array:
	var out: Array = []
	for md in planet.moons:
		if _live_catalog_moon(planet.body_name, md.name) == null:
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

	# drift-mode meshes store GAL_V*(day − epoch) in float32 — rebase the
	# epoch (with a rebuild) before it grows into visible vertex quantization
	if (TrailFrames.mode == TrailFrames.MODE_GALAXY or TrailFrames.mode == TrailFrames.MODE_TRUE) \
			and absf(days - TrailFrames.drift_epoch) > 300.0:
		_rebuild_trail_verts()

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
			# Real-space frame / real-scale view: re-place bodies at their
			# honest barycentric positions (before moons, so a moon's
			# host-anchored display rides the barycentric host). Overwrites
			# display_pos; nb.disp stays sun-anchored for collisions.
			if Units.real_scale or TrailFrames.mode == TrailFrames.MODE_TRUE:
				_apply_barycentric_display()
			_update_moon_hosts()
			_apply_moon_display(dt, SimTime.sim_days(sim_ms))
		_tick_railed(SimTime.sim_days(sim_ms))
	else:
		for b: SimBody in planets:
			var pa := Kepler.body_position_au(b.el, T)
			var pv := Vector3(pa[0], pa[1], pa[2])
			b.r_au = pv.length()
			b.vel_kms = 29.784 * sqrt(maxf(2.0 / b.r_au - 1.0 / b.el.a[0], 0.0))   # vis-viva
			b.pos_au = pv
			b.display_pos = Units.render(pv)
			# advance the realtime trail; rebuild wholesale after a large time jump
			# (Kepler mode: the sun sits at the display origin, so the anchor is ZERO)
			var span := b.trail_max * b.trail_interval
			if days > b.trail_next_day + span or days < b.trail_next_day - span * 1.5:
				backfill_planet_trail(b)
			else:
				while days >= b.trail_next_day:
					var s := Kepler.body_position_au(b.el, SimTime.day_to_t(b.trail_next_day))
					# in Kepler mode the sun rests at the barycenter, so the
					# heliocentric position doubles as bary AND rel
					var s_au := Vector3(s[0], s[1], s[2])
					b.trail_push(b.trail_next_day, Units.to_display(s_au),
							Vector3.ZERO, _focus_abs_kepler(b.trail_next_day), s_au, s_au)
					b.trail_next_day += b.trail_interval
		_tick_moons_kepler(days)
		_tick_railed(days)


## Kepler-mode moons: analytic circles around their home planet, on exactly
## the state _seed_moons() will hand to the integrator — entering physics is
## seamless. Hosts never change here (stealing needs live gravity).
func _tick_moons_kepler(days: float) -> void:
	for mb: SimBody in moons:
		if not mb.simulated:
			continue   # railed — driven by _tick_railed
		var host := mb.host
		if host == null:
			continue
		var om := _moon_omega(mb, Catalog.PLANET_MASS[host.body_name])
		var st := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * days, om)
		var rel := Vector3(st.p[0], st.p[1], st.p[2])
		mb.pos_au = host.pos_au + rel
		mb.display_pos = host.display_pos + Units.moon_offset(rel, mb.disp_k)
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
			var ms_au := Vector3(ms.p[0], ms.p[1], ms.p[2])
			mb.trail_push(day_s, ms_au * mb.disp_k,
					Units.to_display(Vector3(hp[0], hp[1], hp[2])), _focus_abs_kepler(day_s),
					Vector3(hp[0], hp[1], hp[2]) + ms_au, ms_au)
			mb.trail_next_day += mb.trail_interval


func _moon_omega(mb: SimBody, host_mass: float) -> float:
	return MoonMath.omega(mb.a_au, host_mass, mb.mass_solar, g_scale) * mb.orbit_sign


# ================================================================
# Per-body simulation toggle ("on rails")
# ================================================================
## Turning a body's simulation off freezes its motion onto the circular rail
## defined by its state at that moment: it keeps gliding around its anchor
## (host planet, else the sun) but exerts no gravity, feels none, can't
## collide, and costs the integrator nothing. Turning it back on re-injects
## it into live gravity at its current railed state. Moons + customs only.
func set_simulated(body: SimBody, on: bool) -> void:
	if body.is_sun or not (body.custom or body.is_moon) or body.simulated == on:
		return
	if on:
		_unrail(body)
	else:
		_rail(body)


func _rail(body: SimBody) -> void:
	var days := SimTime.sim_days(sim_ms)
	var i := nb.index_of(body) if physics_active else -1
	var rel_p: Vector3
	var rel_v: Vector3
	if i >= 0:
		var anchor: SimBody = body.host if (body.is_moon and body.host != null) else sun
		var ai := maxi(nb.index_of(anchor), 0)
		rel_p = Vector3(nb.px[i] - nb.px[ai], nb.py[i] - nb.py[ai], nb.pz[i] - nb.pz[ai])
		rel_v = Vector3(nb.vx[i] - nb.vx[ai], nb.vy[i] - nb.vy[ai], nb.vz[i] - nb.vz[ai])
	elif body.is_moon and not body.custom and body.host != null:
		# Kepler-mode catalog moon: freeze its analytic circle in place
		var om := _moon_omega(body, Catalog.PLANET_MASS.get(body.host.body_name, 3.0e-6))
		var st := MoonMath.rel_state(body.a_au, body.incl_deg, body.phase0 + om * days, om)
		rel_p = Vector3(st.p[0], st.p[1], st.p[2])
		rel_v = Vector3(st.v[0], st.v[1], st.v[2])
	else:
		return   # nothing to freeze from
	_freeze_rail(body, rel_p, rel_v, days)
	if i >= 0:
		var bary_before := nb.barycenter()
		nb.remove_at(i)
		nb.absorb_frame_shift(bary_before)
		nb.refresh_display(true)
		nb.compute_accel(g_scale)
	body.trail_clear()
	_drive_railed(body, days)
	Events.toast_requested.emit("%s is on rails — gliding, no gravity" % body.body_name)
	# with nothing left to integrate, planets can return to the exact ephemeris
	if physics_active and not _has_simulated_customs() and not _has_simulated_custom_moons() and not physics_permanent:
		exit_physics()


## capture an anchor-relative state as the body's frozen circular rail
func _freeze_rail(body: SimBody, rel_p: Vector3, rel_v: Vector3, days: float) -> void:
	body.rail_a = maxf(rel_p.length(), 1e-9)
	body.rail_u = rel_p / body.rail_a
	var tang := rel_v - rel_v.dot(body.rail_u) * body.rail_u
	if tang.length_squared() > 1e-24:
		body.rail_w = tang.normalized()
		body.rail_omega = tang.length() / body.rail_a
	else:
		# radial or zero velocity picks no circle — glide horizontally
		# prograde at the circular rate for the anchor's mass
		var anchor: SimBody = body.host if (body.is_moon and body.host != null) else sun
		var w := body.rail_u.cross(Vector3.UP)
		if w.length_squared() < 1e-12:
			w = body.rail_u.cross(Vector3.RIGHT)
		body.rail_w = w.normalized()
		body.rail_omega = MoonMath.omega(body.rail_a, mass_of(anchor), 0.0, g_scale)
	body.rail_day0 = days
	body.simulated = false
	body.trail_interval = (TAU / maxf(body.rail_omega, 1e-9)) / 128.0


func _unrail(body: SimBody) -> void:
	var days := SimTime.sim_days(sim_ms)
	if not physics_active and body.is_moon and not body.custom and body.host != null:
		# Kepler mode: the rail was frozen from the moon's own analytic circle
		# and advances at the same rate — resuming the ephemeris is seamless
		body.simulated = true
		body.trail_clear()
		Events.toast_requested.emit("%s rejoined the simulation" % body.body_name)
		return
	enter_physics()
	var th := body.rail_omega * (days - body.rail_day0)
	var rel := (body.rail_u * cos(th) + body.rail_w * sin(th)) * body.rail_a
	var tang := (body.rail_w * cos(th) - body.rail_u * sin(th)) * (body.rail_a * body.rail_omega)
	var anchor: SimBody = body.host if (body.is_moon and body.host != null) else sun
	var ai := maxi(nb.index_of(anchor), 0)
	var bary_before := nb.barycenter()
	var idx := nb.add_body(body, base_mass_of(body))
	nb.m[idx] = nb.base_m[idx] * body.mass_scale
	nb.px[idx] = nb.px[ai] + rel.x
	nb.py[idx] = nb.py[ai] + rel.y
	nb.pz[idx] = nb.pz[ai] + rel.z
	nb.vx[idx] = nb.vx[ai] + tang.x
	nb.vy[idx] = nb.vy[ai] + tang.y
	nb.vz[idx] = nb.vz[ai] + tang.z
	nb.zero_momentum()
	nb.absorb_frame_shift(bary_before)
	nb.refresh_display(true)
	nb.compute_accel(g_scale)
	body.simulated = true
	body.bind_t = 1.0
	body.trail_clear()
	Events.toast_requested.emit("%s rejoined the simulation" % body.body_name)


## unsimulated bodies glide on their frozen circles — pure kinematics, both modes
func _tick_railed(days: float) -> void:
	for mb: SimBody in moons:
		if not mb.simulated:
			_drive_railed(mb, days)
	for b: SimBody in customs:
		if not b.simulated:
			_drive_railed(b, days)


func _drive_railed(b: SimBody, days: float) -> void:
	var th := b.rail_omega * (days - b.rail_day0)
	var rel := (b.rail_u * cos(th) + b.rail_w * sin(th)) * b.rail_a
	var tang := (b.rail_w * cos(th) - b.rail_u * sin(th)) * (b.rail_a * b.rail_omega)
	var anchor: SimBody = b.host if (b.is_moon and b.host != null) else sun
	b.pos_au = anchor.pos_au + rel
	b.r_au = b.pos_au.length()
	b.vel_display = tang
	b.vel_kms = (_vel_au_day(anchor) + tang).length() * Units.KMS_PER_AUDAY
	# sun-anchored display — kept as the trail's frame-independent local/anchor.
	# In the real-scale view the anchor's display_pos is linear, so the stored
	# samples are built from the CANONICAL compressed anchor instead — switching
	# the scale back must find uncorrupted history.
	var a_disp := anchor.display_pos
	if Units.real_scale:
		a_disp = _canon_display(anchor)
	var local := rel * b.disp_k if (b.is_moon and b.host != null) else Units.to_display(rel)
	# raw barycentric offset (AU) for the Real-space frame: the anchor's own
	# offset plus this body's anchor-relative rel
	var bary := _bary_offset_of(anchor) + rel
	if b.is_moon and b.host != null:
		# bound moons ride their host in either scale (exaggerated / true offset)
		b.display_pos = anchor.display_pos + Units.moon_offset(rel, b.disp_k)
	elif Units.real_scale:
		b.display_pos = bary * Units.REAL_AU
	elif TrailFrames.mode == TrailFrames.MODE_TRUE:
		b.display_pos = Units.to_display(bary)
	else:
		b.display_pos = a_disp + local
	if days >= b.trail_next_day:
		var fa := Vector3.ZERO
		if TrailFrames.mode == TrailFrames.MODE_FOCUS and TrailFrames.focus != null:
			fa = TrailFrames.focus.display_pos
		b.trail_push(days, local, a_disp, fa, bary, rel)
		b.trail_next_day = days + b.trail_interval


## Barycenter of the live integration (Vector3), or ZERO outside physics —
## the once-per-frame input to nb.bary_offset_au for the Real-space frame.
func _bary_now() -> Vector3:
	return nb.barycenter() if (physics_active and nb != null) else Vector3.ZERO


## Frame-corrected barycentric offset (AU) of any body for the Real-space
## frame — resolves bodies that may sit outside the integrator (railed hosts,
## Kepler mode), where the sun rests at the barycenter so heliocentric ==
## barycentric.
func _bary_offset_of(b: SimBody) -> Vector3:
	if physics_active and nb != null:
		var i := nb.index_of(b)
		if i >= 0:
			return nb.bary_offset_au(i, nb.barycenter())
	return b.pos_au


## Honest-barycentric render pass, shared by the Real-space frame (MODE_TRUE,
## single compression) and the real-scale view (linear) — Units.render picks
## the mapping. Overwrites each non-moon body's display_pos so a trail built
## from the same mapping ends exactly on its body. nb.disp stays sun-anchored
## for collisions; this touches render positions only.
func _apply_barycentric_display() -> void:
	var bary := nb.barycenter()
	sun.display_pos = Units.render(nb.bary_offset_au(0, bary))
	for i in range(1, nb.count()):
		var b: SimBody = nb.bodies[i]
		if b.is_moon:
			continue
		b.display_pos = Units.render(nb.bary_offset_au(i, bary))


## A body's display position in the CANONICAL compressed sun-anchored frame,
## regardless of the active render scale. Trail samples (local/anchor) are
## stored in this frame, so pushes taken while the real-scale view is active
## read anchors from here instead of the (linear) display_pos.
func _canon_display(b: SimBody) -> Vector3:
	if physics_active and nb != null:
		var i := nb.index_of(b)
		if i >= 0:
			return nb.disp[i]
		return nb.disp[0] + Units.to_display(b.pos_au)   # railed: sun-anchored build
	if b.is_sun:
		return Vector3.ZERO
	return Units.to_display(b.pos_au)


## a body's current velocity vector in AU/day (best effort in either mode)
func _vel_au_day(b: SimBody) -> Vector3:
	if physics_active and nb != null:
		var i := nb.index_of(b)
		if i >= 0:
			return Vector3(nb.vx[i], nb.vy[i], nb.vz[i])
	if not b.simulated:
		var th := b.rail_omega * (SimTime.sim_days(sim_ms) - b.rail_day0)
		var tang := (b.rail_w * cos(th) - b.rail_u * sin(th)) * (b.rail_a * b.rail_omega)
		var anchor: SimBody = b.host if (b.is_moon and b.host != null) else sun
		return _vel_au_day(anchor) + tang
	if not b.is_sun and not b.el.is_empty():
		var s := Kepler.state_vector(b.el, SimTime.julian_centuries(sim_ms))
		return Vector3(s.v[0], s.v[1], s.v[2])
	return Vector3.ZERO


## Which bodies force the integrator below its 0.1-day cruise step, and by
## how much: [{ body, factor }] sorted worst-first. factor 7 means the whole
## system needs 7× the substeps because of that body. Empty outside physics.
func step_costs() -> Array:
	if not physics_active:
		return []
	var taus := nb.tau_body   # refreshed every compute_accel; no extra O(n²) pass
	var out: Array = []
	for i in nb.count():
		var h := clampf(taus[i] / 20.0, H_MIN, 0.1)
		var f := 0.1 / h
		if f > 1.05:
			out.append({ body = nb.bodies[i], factor = f })
	out.sort_custom(func(a, b) -> bool: return a.factor > b.factor)
	return out


## Conserved quantities of the live integration (energy / |momentum| /
## |angular momentum|) — diagnostics for the regression tests and perf panel.
## Empty outside physics mode.
func conserved() -> Dictionary:
	if not physics_active:
		return {}
	return nb.conserved(g_scale)


## analytic display position of a Kepler-mode moon at an arbitrary sim-day
## (in the active scale — Units.render/moon_offset pick the mapping)
func _moon_kepler_display(mb: SimBody, day: float, om: float) -> Vector3:
	var hp := Kepler.body_position_au(mb.host.el, SimTime.day_to_t(day))
	var st := MoonMath.rel_state(mb.a_au, mb.incl_deg, mb.phase0 + om * day, om)
	return Units.render(Vector3(hp[0], hp[1], hp[2])) + Units.moon_offset(Vector3(st.p[0], st.p[1], st.p[2]), mb.disp_k)


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
		if mb.simulated:   # railed moons stay kinematic, outside the integrator
			nb.add_body(mb, mb.mass_solar)
	physics_active = true
	_seed_planets()
	Events.mode_changed.emit()


func exit_physics() -> void:
	physics_active = false
	for b in all_bodies():
		b.nb_index = -1   # rows are gone; a fresh enter_physics reassigns them
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
		# on the host (the sun while free-flying). While the real-scale view
		# is active the stored local/anchor are built from the canonical
		# compressed frame (nb.disp), so history survives a scale switch.
		if day >= mb.trail_next_day:
			var hi := nb.index_of(mb.host) if mb.host != null else -1
			# raw anchor-relative offset in AU: host-relative while bound,
			# sun-relative free — the real-scale frames render from it
			var rel: Vector3
			if hi >= 0:
				rel = Vector3(nb.px[mi] - nb.px[hi], nb.py[mi] - nb.py[hi], nb.pz[mi] - nb.pz[hi])
			else:
				rel = Vector3(nb.px[mi] - nb.px[0], nb.py[mi] - nb.py[0], nb.pz[mi] - nb.pz[0])
			var anchor := sun.display_pos
			if mb.host != null:
				anchor = mb.host.display_pos
			var local := mb.display_pos - anchor
			if Units.real_scale:
				if hi >= 0:
					anchor = nb.disp[hi]
					local = rel * mb.disp_k
				else:
					anchor = nb.disp[0]
					local = helio - anchor
			var fa := Vector3.ZERO
			if TrailFrames.mode == TrailFrames.MODE_FOCUS and TrailFrames.focus != null:
				fa = TrailFrames.focus.display_pos
			mb.trail_push(day, local, anchor, fa, nb.bary_offset_au(mi, _bary_now()), rel)
			mb.trail_next_day = day + mb.trail_interval


func _moon_mapped(mb: SimBody, host: SimBody, k: float, mi: int, helio: Vector3) -> Vector3:
	var hi := nb.index_of(host) if host != null else -1
	if hi < 0:
		# free moon: standard heliocentric mapping, honest barycentric at real scale
		if Units.real_scale:
			return nb.bary_offset_au(mi, _bary_now()) * Units.REAL_AU
		return helio
	var rel := Vector3(nb.px[mi] - nb.px[hi], nb.py[mi] - nb.py[hi], nb.pz[mi] - nb.pz[hi])
	return host.display_pos + Units.moon_offset(rel, k)


## Route one frame's integration to the compiled kernel when ready, else the
## pure-GDScript path. Both keep identical game semantics; only the O(n²) block
## loop moves off GDScript.
func _step_physics(dt_days: float, end_day: float) -> void:
	if _kernel != null and _kernel.ready():
		_step_physics_native(dt_days, end_day)
	else:
		_step_physics_gdscript(dt_days, end_day)


func _step_physics_gdscript(dt_days: float, end_day: float) -> void:
	var day := end_day - dt_days
	var remaining := dt_days
	var steps := 0
	var work := 0.0            # full-force-pass equivalents (the budget currency)
	var pair_evals := 0
	var us_step := 0
	var us_display := 0
	var us_collide := 0
	var us_trails := 0
	var h_last := 0.0
	while remaining > 1e-9:
		if work >= MAX_SUBSTEPS:
			break
		steps += 1
		# One block advances H days. Cruise at 0.1 d; during close encounters
		# shrink to H_TAU_FRAC·tau_min so the tightest pair still resolves at
		# the deepest rung. H_MIN keeps a near-contact pair from stalling the
		# budget — below it the merge rule resolves the encounter anyway. Fast
		# moons subcycle inside the block instead of shrinking H for everyone.
		var h: float
		if USE_BLOCK:
			h = minf(clampf(nb.tau_min * H_TAU_FRAC, H_MIN, 0.1), remaining)
		else:
			h = minf(clampf(nb.tau_min / 20.0, H_MIN, 0.1), remaining)
		var t0 := Time.get_ticks_usec()
		var nn := nb.count()
		if USE_BLOCK:
			nb.step_block(h, g_scale)
			work += 1.0 + 2.0 * float(nb.last_fast_evals) / maxf(nn * nn, 1.0)
			pair_evals += nn * (nn - 1) / 2 + nb.last_fast_evals
		else:
			nb.leapfrog_substep(h, g_scale)
			work += 1.0
			pair_evals += nn * (nn - 1) / 2
		var t1 := Time.get_ticks_usec()
		us_step += t1 - t0
		h_last = h
		day += h
		remaining -= h

		# barycentric display positions — once per block (H ≤ 0.1 d, the old
		# cruise cadence); drives trails & collisions
		nb.refresh_display(false)
		var t2 := Time.get_ticks_usec()
		us_display += t2 - t1

		# collisions: closest approach over the block's motion, so fast bodies
		# can't tunnel through each other between blocks. Bodies merge when
		# their rendered meshes substantially overlap.
		# Bound moons render at host + real offset × disp_k, so their raw
		# display position sits INSIDE the host's exaggerated sphere — test
		# those pairs in real space, sharpened by enc_distance (the finest
		# separation seen across a subcycling moon's substeps), scaled into
		# moon display units. Free pairs use the display-space swept test as
		# before; H shrinks toward any free-free collision (tau_min drops), so
		# the straight-segment test stays accurate exactly when it must.
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
					var rmin := nb.real_distance(i, j)
					var enc := nb.enc_distance(i, j)
					if enc < rmin:
						rmin = enc
					hit = rmin * bound_k < 0.75 * (a.size + b.size)
				else:
					hit = nb.swept_distance(i, j) < 0.75 * (a.size + b.size)
				if hit:
					_merge_bodies(i, j)
					merged = true
					break
		var t3 := Time.get_ticks_usec()
		us_collide += t3 - t2

		# trails: sample on cadence, or sooner whenever the velocity direction
		# has swung > 4° since the last sample — sharp encounters stay smooth.
		# (Moons are skipped: their display space is amplified per-host, so
		# their trails advance once per frame in _apply_moon_display.)
		# Samples are sun-anchored: local = heliocentric display offset,
		# anchor = the sun's absolute display position this substep.
		var focus_abs := _focus_abs_live()
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
				var rel_sun := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0])
				b.trail_push(day, nb.disp[i] - nb.disp[0], nb.disp[0], focus_abs,
						nb.bary_offset_au(i, _bary_now()), rel_sun)
				var vm2 := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
				if vm2 == 0.0:
					vm2 = 1.0
				b.trail_lv = Vector3(nb.vx[i] / vm2, nb.vy[i] / vm2, nb.vz[i] / vm2)
				b.trail_lv_ok = true
				b.trail_interval = _trail_interval(b, rel_sun.length())
				b.trail_next_day = day + b.trail_interval
		us_trails += Time.get_ticks_usec() - t3
	perf = {
		steps = steps, work = work, pair_evals = pair_evals, h_last = h_last,
		us_step = us_step, us_display = us_display,
		us_collide = us_collide, us_trails = us_trails,
	}
	# hit the substep budget: let the clock wait for the physics rather than
	# corrupt the integration. lag_ratio feeds the HUD "physics-limited" badge.
	lag_ratio = lag_ratio * 0.9 + 0.1 * (1.0 if dt_days <= 0.0 else (dt_days - remaining) / dt_days)
	if remaining > 1e-9:
		sim_ms -= remaining * 86400000.0


## Native path: the compiled kernel runs the whole frame's block loop
## (integration + display + collision detection); GDScript keeps the game
## logic. On a detected collision the kernel returns the pair and the leftover
## time; we resolve the merge here and continue for the remainder. Trails
## advance once per frame (moons still handled in _apply_moon_display).
func _step_physics_native(dt_days: float, end_day: float) -> void:
	var t_start := Time.get_ticks_usec()
	var remaining := dt_days
	var total_work := 0.0
	var total_blocks := 0
	var sizes := _collect_sizes()
	var bks := _collect_bound_k()
	var guard := 0
	while remaining > 1e-9:
		guard += 1
		if guard > nb.count() + 5:
			break   # safety against a pathological merge loop
		var budget_left := float(MAX_SUBSTEPS_NATIVE) - total_work
		if budget_left <= 0.0:
			break
		var r := _kernel.advance(nb, sizes, bks, nb.frame_corr, g_scale, remaining,
				H_MIN, 0.1, H_TAU_FRAC, budget_left)
		if r.is_empty():
			_step_physics_gdscript(remaining, end_day)   # bridge hiccup — finish on GDScript
			return
		_apply_kernel_result(r)
		total_work += float(r.work)
		total_blocks += int(r.blocks)
		if int(r.status) == NativeKernel.ST_MERGE:
			_merge_bodies(int(r.merge_i), int(r.merge_j))
			sizes = _collect_sizes()
			bks = _collect_bound_k()
			remaining = float(r.remaining_days)
		else:
			remaining = float(r.remaining_days)
			break
	_sample_planet_trails(end_day)
	var nn := nb.count()
	perf = {
		steps = total_blocks, work = total_work,
		pair_evals = total_blocks * nn * (nn - 1) / 2, h_last = 0.0,
		us_step = Time.get_ticks_usec() - t_start,
		us_display = 0, us_collide = 0, us_trails = 0,
	}
	lag_ratio = lag_ratio * 0.9 + 0.1 * (1.0 if dt_days <= 0.0 else (dt_days - remaining) / dt_days)
	if remaining > 1e-9:
		sim_ms -= remaining * 86400000.0


func _collect_sizes() -> PackedFloat64Array:
	var n := nb.count()
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		out[i] = (nb.bodies[i] as SimBody).size
	return out


## bound-moon display amplification per body (0 = free / not a moon); the
## kernel tests bound-moon collisions in real space scaled by this.
func _collect_bound_k() -> PackedFloat64Array:
	var n := nb.count()
	var out := PackedFloat64Array()
	out.resize(n)
	for i in n:
		var b: SimBody = nb.bodies[i]
		out[i] = b.disp_k if (b.is_moon and b.host != null) else 0.0
	return out


func _apply_kernel_result(r: Dictionary) -> void:
	nb.px = r.px; nb.py = r.py; nb.pz = r.pz
	nb.vx = r.vx; nb.vy = r.vy; nb.vz = r.vz
	nb.tau_min = float(r.tau_min)
	nb.tau_body = r.tau_body
	var n := nb.count()
	if nb.disp.size() != n:
		nb.disp.resize(n)
	var disp: PackedFloat64Array = r.disp
	for i in n:
		nb.disp[i] = Vector3(disp[3 * i], disp[3 * i + 1], disp[3 * i + 2])


## Per-frame planet/custom trail sampling (same cadence + angle trigger as the
## old per-substep pass, now driven once from the frame's final positions).
func _sample_planet_trails(day: float) -> void:
	var focus_abs := _focus_abs_live()
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
			var rel_sun := Vector3(nb.px[i] - nb.px[0], nb.py[i] - nb.py[0], nb.pz[i] - nb.pz[0])
			b.trail_push(day, nb.disp[i] - nb.disp[0], nb.disp[0], focus_abs,
					nb.bary_offset_au(i, _bary_now()), rel_sun)
			var vm2 := sqrt(nb.vx[i] * nb.vx[i] + nb.vy[i] * nb.vy[i] + nb.vz[i] * nb.vz[i])
			if vm2 == 0.0:
				vm2 = 1.0
			b.trail_lv = Vector3(nb.vx[i] / vm2, nb.vy[i] / vm2, nb.vz[i] / vm2)
			b.trail_lv_ok = true
			b.trail_interval = _trail_interval(b, rel_sun.length())
			b.trail_next_day = day + b.trail_interval


## The focus body's absolute display position right now, in the ACTIVE scale —
## the `focus_abs` for physics-mode trail pushes. ZERO unless the FOCUS frame
## is active, so other modes pay nothing.
func _focus_abs_live() -> Vector3:
	if TrailFrames.mode != TrailFrames.MODE_FOCUS or TrailFrames.focus == null:
		return Vector3.ZERO
	var fi := nb.index_of(TrailFrames.focus)
	if fi < 0:
		return TrailFrames.focus.display_pos
	if Units.real_scale:
		return nb.bary_offset_au(fi, nb.barycenter()) * Units.REAL_AU
	return nb.disp[fi]


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
	if Units.real_scale or TrailFrames.mode == TrailFrames.MODE_TRUE:
		# the render frame is honest barycentric — map the flash to where the
		# collision appears on screen (row li's position is still intact)
		impact = Units.render(nb.bary_offset_au(li, nb.barycenter()))
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
	# anchor the relative state to the host's row (the sun by default); a
	# railed host has no row — anchor on its kinematic state instead
	var ai := 0
	if host != null:
		ai = nb.index_of(host)
	var ap: Vector3
	var av: Vector3
	if ai >= 0:
		ap = Vector3(nb.px[ai], nb.py[ai], nb.pz[ai])
		av = Vector3(nb.vx[ai], nb.vy[ai], nb.vz[ai])
	else:
		ap = Vector3(nb.px[0], nb.py[0], nb.pz[0]) + host.pos_au
		av = _vel_au_day(host)
	nb.px[idx] = st.p[0] + ap.x
	nb.py[idx] = st.p[1] + ap.y
	nb.pz[idx] = st.p[2] + ap.z
	nb.vx[idx] = st.v[0] + av.x
	nb.vy[idx] = st.v[1] + av.y
	nb.vz[idx] = st.v[2] + av.z
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
	# (railed bodies don't hold physics open: they're kinematic in either mode)
	if physics_active and not _has_simulated_customs() and not _has_simulated_custom_moons() and not physics_permanent:
		exit_physics()


## removes a moon (user-deleted custom moon, or a merge loser)
func remove_moon(body: SimBody, preserve_frame: bool = true) -> void:
	moons.erase(body)
	_remove_from_system(body, preserve_frame)
	if physics_active and not _has_simulated_customs() and not _has_simulated_custom_moons() and not physics_permanent:
		exit_physics()


func _remove_planet(body: SimBody) -> void:
	planets.erase(body)
	_remove_from_system(body, false)


func _remove_from_system(body: SimBody, preserve_frame: bool) -> void:
	# railed moons anchored on the departing body get refrozen around the sun
	# at their current absolute state, so they keep gliding instead of
	# circling a ghost
	var days := SimTime.sim_days(sim_ms)
	for mb: SimBody in moons:
		if mb != body and not mb.simulated and mb.host == body:
			var th := mb.rail_omega * (days - mb.rail_day0)
			var rel := (mb.rail_u * cos(th) + mb.rail_w * sin(th)) * mb.rail_a
			var tang := (mb.rail_w * cos(th) - mb.rail_u * sin(th)) * (mb.rail_a * mb.rail_omega)
			var abs_v := _vel_au_day(body) + tang
			mb.host = null
			mb.host_prev = null
			_freeze_rail(mb, body.pos_au + rel, abs_v, days)
			mb.trail_clear()
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
	if not body.simulated:
		body.mass_scale = mult   # inert while on rails; applied on rejoin
		return
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
		var s_au := Vector3(s[0], s[1], s[2])
		b.trail_push(day_s, Units.to_display(s_au),
				Vector3.ZERO, _focus_abs_kepler(day_s), s_au, s_au)
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
	return Units.render(Vector3(s[0], s[1], s[2]))


## selection drives the FOCUS frame's reference body (falls back to the sun)
func _on_selection_for_trails(body) -> void:
	var f: SimBody = body if body != null else sun
	if TrailFrames.focus == f:
		return
	TrailFrames.focus = f
	if TrailFrames.mode == TrailFrames.MODE_FOCUS:
		_rebuild_trail_verts()


## frame mode or focus changed: recompute every cached vertex from the
## frame-independent samples — nothing is cleared, switching is lossless.
## Every rebuild also rebases the drift epoch (see TrailFrames.drift_epoch),
## so drift-mode vertices stay small near the trail head.
func _rebuild_trail_verts() -> void:
	TrailFrames.drift_epoch = SimTime.sim_days(sim_ms)
	for b in all_bodies():
		b.trail_rebuild()
