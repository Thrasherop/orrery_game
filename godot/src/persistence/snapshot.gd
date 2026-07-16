class_name Snapshot
## Captures/applies the full simulation state as a JSON-safe Dictionary
## (String/float/bool/Array/Dictionary only — write with
## JSON.stringify(d, "", false, true): full_precision is required because
## sim_ms (~1.7e12) and the N-body state vectors need all float64 digits).
##
## Kepler-mode snapshots carry no positions — the ephemeris reproduces them
## from `el` + sim_ms. Physics-mode snapshots store each body's raw N-body
## row (`phys`) inline, and bodies are re-added sun-first, planets, then
## customs, preserving nbody's index-0-is-the-sun invariant.
##
## Not persisted: trails (backfilled/cleared on apply), selection (always
## dropped on apply — restored SimBodys are new objects), and per-frame
## derived fields (recomputed by one tick(0.0)).

const VERSION := 1


static func capture(sim: Simulation, rig: CameraRig) -> Dictionary:
	var d := {
		version = VERSION,
		sim = {
			sim_ms = sim.sim_ms,
			speed = sim.speed,
			playing = sim.playing,
			g_scale = sim.g_scale,
			physics_active = sim.physics_active,
			physics_permanent = sim.physics_permanent,
			custom_count = sim.custom_count,
		},
		sun = { mass_scale = sim.sun.mass_scale },
		planets = [],
		customs = [],
		camera = _camera_state(rig),
		toggles = {
			orbits = Events.show_orbits,
			labels = Events.show_labels,
			vectors = Events.show_vectors,
		},
	}
	if sim.physics_active:
		d.sun.phys = _phys_of(sim.nb, sim.sun)
		d.frame_corr = _v3(sim.nb.frame_corr)
	for b: SimBody in sim.planets:
		var e := { name = b.body_name, size = b.size, mass_scale = b.mass_scale }
		if sim.physics_active:
			e.phys = _phys_of(sim.nb, b)
		d.planets.append(e)
	for b: SimBody in sim.customs:
		d.customs.append({
			name = b.body_name,
			color = b.color.to_html(false),
			is_star = b.is_star,
			mass_e = b.mass_e,
			size = b.size,
			mass_scale = b.mass_scale,
			body_type = b.body_type,
			desc = b.desc,
			palette_index = int(b.tex.get("palette_index", 0)),
			phys = _phys_of(sim.nb, b),
		})
	return d


## Rebuild the running simulation (and camera) from a snapshot.
## Returns false without touching anything when the data is invalid.
static func apply(sim: Simulation, rig: CameraRig, d: Dictionary) -> bool:
	if not validate(d):
		Events.toast_requested.emit("Save data is invalid — not loaded")
		return false
	var s: Dictionary = d.sim

	# selection first: everything below replaces or mutates bodies
	Events.deselect_requested.emit()

	# quietly leave physics — mode_changed is emitted once at the end
	# (exit_physics() would clear the sun trail and signal mid-rebuild)
	sim.physics_active = false
	sim.nb = null

	# planets: diff against the snapshot by name (absent name = merged away)
	var wanted := {}
	for e in d.planets:
		wanted[e.name] = true
	for b: SimBody in sim.planets.duplicate():
		if not wanted.has(b.body_name):
			sim.planets.erase(b)
			Events.body_removed.emit(b)
	var live := {}
	for b: SimBody in sim.planets:
		live[b.body_name] = b
	var defs := {}
	for def in Catalog.make_planets():
		defs[def.body_name] = def
	var planet_rows: Array = []   # [SimBody, snapshot entry], snapshot order
	for e in d.planets:
		var b: SimBody
		if live.has(e.name):
			b = live[e.name]
		elif defs.has(e.name):
			b = sim.make_planet_from_def(defs[e.name])
			Events.body_added.emit(b)
		else:
			continue   # unknown planet name — skip rather than fail the load
		b.size = float(e.size)
		b.mass_scale = float(e.get("mass_scale", 1.0))
		planet_rows.append([b, e])
	var new_planets: Array = []
	for row in planet_rows:
		new_planets.append(row[0])
	sim.planets = new_planets

	# customs: replace wholesale (their textures are the boot-time palette set)
	for b: SimBody in sim.customs:
		Events.body_removed.emit(b)
	sim.customs.clear()
	var custom_rows: Array = []
	for e in d.customs:
		var b := SimBody.new()
		b.body_name = e.name
		b.color = Color(str(e.color))
		b.custom = true
		b.is_star = bool(e.get("is_star", false))
		b.mass_e = float(e.get("mass_e", 1.0))
		b.size = float(e.size)
		b.mass_scale = float(e.get("mass_scale", 1.0))
		b.body_type = str(e.get("body_type", "Custom body"))
		b.desc = str(e.get("desc", ""))
		b.tex = { kind = "custom", palette_index = int(e.get("palette_index", 0)) }
		b.init_trail(Simulation.TRAIL_MAX, 0.5)
		sim.customs.append(b)
		custom_rows.append([b, e])
		Events.body_added.emit(b)

	sim.sun.mass_scale = float(d.sun.get("mass_scale", 1.0))
	sim.sim_ms = float(s.sim_ms)
	sim.speed = float(s.speed)
	sim.playing = bool(s.playing)
	sim.g_scale = float(s.g_scale)
	sim.physics_permanent = bool(s.get("physics_permanent", false))
	sim.custom_count = int(s.get("custom_count", d.customs.size()))

	if bool(s.physics_active):
		var nb := NBodySystem.new()
		var rows: Array = [[sim.sun, d.sun]]
		rows.append_array(planet_rows)
		rows.append_array(custom_rows)
		for row in rows:
			var i := nb.add_body(row[0], 1.0)
			var ph: Dictionary = row[1].phys
			nb.px[i] = ph.p[0]; nb.py[i] = ph.p[1]; nb.pz[i] = ph.p[2]
			nb.vx[i] = ph.v[0]; nb.vy[i] = ph.v[1]; nb.vz[i] = ph.v[2]
			nb.m[i] = float(ph.m)
			nb.base_m[i] = float(ph.base_m)
		nb.frame_corr = _to_v3(d.get("frame_corr", [0.0, 0.0, 0.0]))
		nb.refresh_display(true)
		nb.compute_accel(sim.g_scale)
		sim.nb = nb
		sim.physics_active = true
		for b: SimBody in sim.all_bodies():
			b.trail_clear()   # restored state doesn't match any on-screen history
	else:
		sim.sun.trail_clear()
		sim.sun.display_pos = Vector3.ZERO
		for b: SimBody in sim.planets:
			sim.backfill_planet_trail(b)

	sim.tick(0.0)   # recompute r_au / vel_kms / display_pos in either mode

	var t: Dictionary = d.get("toggles", {})
	Events.set_show_orbits(bool(t.get("orbits", true)))
	Events.set_show_labels(bool(t.get("labels", true)))
	Events.set_show_vectors(bool(t.get("vectors", true)))

	Events.bodies_changed.emit()
	Events.mode_changed.emit()

	if rig != null:
		var c: Dictionary = d.get("camera", _default_camera())
		rig.apply_view(_to_v3(c.get("target", [0.0, 0.0, 0.0])),
			float(c.get("yaw", 0.0)), float(c.get("pitch", 0.0)),
			float(c.get("dist", 150.0)))
	return true


## The pristine solar system at the current date — Reset applies this.
static func default_snapshot() -> Dictionary:
	var planets: Array = []
	for def in Catalog.make_planets():
		planets.append({ name = def.body_name, size = def.size, mass_scale = 1.0 })
	return {
		version = VERSION,
		sim = {
			sim_ms = Time.get_unix_time_from_system() * 1000.0,
			speed = 604800.0,
			playing = true,
			g_scale = 1.0,
			physics_active = false,
			physics_permanent = false,
			custom_count = 0,
		},
		sun = { mass_scale = 1.0 },
		planets = planets,
		customs = [],
		camera = _default_camera(),
		toggles = { orbits = true, labels = true, vectors = true },
	}


static func validate(d) -> bool:
	if typeof(d) != TYPE_DICTIONARY:
		return false
	var v := int(d.get("version", 0))
	if v < 1 or v > VERSION:
		return false
	for k in ["sim", "sun", "planets", "customs"]:
		if not d.has(k):
			return false
	if typeof(d.sim) != TYPE_DICTIONARY or not d.sim.has("sim_ms"):
		return false
	if typeof(d.planets) != TYPE_ARRAY or typeof(d.customs) != TYPE_ARRAY:
		return false
	if bool(d.sim.get("physics_active", false)):
		if not _has_phys(d.sun):
			return false
		for e in d.planets:
			if not _has_phys(e):
				return false
		for e in d.customs:
			if not _has_phys(e):
				return false
	elif not (d.customs as Array).is_empty():
		return false   # custom bodies only exist in physics mode
	return true


static func _has_phys(e) -> bool:
	if typeof(e) != TYPE_DICTIONARY or typeof(e.get("phys")) != TYPE_DICTIONARY:
		return false
	var ph: Dictionary = e.phys
	return typeof(ph.get("p")) == TYPE_ARRAY and (ph.p as Array).size() == 3 \
		and typeof(ph.get("v")) == TYPE_ARRAY and (ph.v as Array).size() == 3 \
		and ph.has("m") and ph.has("base_m")


static func _phys_of(nb: NBodySystem, body: SimBody) -> Dictionary:
	var i := nb.index_of(body)
	return {
		p = [nb.px[i], nb.py[i], nb.pz[i]],
		v = [nb.vx[i], nb.vy[i], nb.vz[i]],
		m = nb.m[i],
		base_m = nb.base_m[i],
	}


static func _camera_state(rig: CameraRig) -> Dictionary:
	if rig == null:
		return _default_camera()
	var vs := rig.view_state()
	return {
		target = _v3(vs.target),
		yaw = vs.yaw,
		pitch = vs.pitch,
		dist = vs.dist,
	}


## matches CameraRig._ready(): camera at (48, 62, 148) looking at the origin
static func _default_camera() -> Dictionary:
	var off := Vector3(48, 62, 148)
	var dist := off.length()
	return {
		target = [0.0, 0.0, 0.0],
		yaw = atan2(off.x, off.z),
		pitch = asin(off.y / dist),
		dist = dist,
	}


static func _v3(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _to_v3(a) -> Vector3:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() != 3:
		return Vector3.ZERO
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
