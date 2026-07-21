extends Node
## Visual harness for the real-scale view: boots the real main scene, toggles
## real scale on via the event bus (same path the dock button uses), captures
## the wide view, a zoomed inner system, and the round trip back.
##   godot --path godot res://tests/visual_real_scale.tscn


func _ready() -> void:
	get_window().size = Vector2i(1600, 900)
	await get_tree().process_frame
	Events.set_real_scale(false)   # deterministic start regardless of prefs
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/realscale_1_compressed.png")

	# toggle on: planets shrink to dots, distances go linear
	Events.set_real_scale(true)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/realscale_2_on_wide.png")

	# zoom toward the inner system: only orbits + the sun's star-point remain
	var rig: CameraRig = main.camera_rig
	rig.apply_view(Vector3.ZERO, rig.yaw_goal, rig.pitch_goal, 24.0)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/realscale_3_inner.png")

	# physics mode: inject a body, make sure trails stay glued at real scale
	var sim: Simulation = main.sim
	sim.add_custom_body({
		name = "Wanderer", mass_e = 100.0, dist_au = 1.5,
		lon_deg = 120.0, lat_deg = 5.0, speed_kms = 18.0, dir_deg = 15.0,
	})
	Events.deselect_requested.emit()
	sim.speed = 2629800.0
	rig.apply_view(Vector3.ZERO, rig.yaw_goal, rig.pitch_goal, 60.0)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/realscale_4_physics.png")

	# dive all the way into Earth: select, let the fly-to land, then drop the
	# camera to ~3 true radii — the real disc should fill a good chunk of frame
	sim.speed = 86400.0
	for b in sim.planets:
		if b.body_name == "Earth":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.6).timeout
	var earth: SimBody = Events.selected
	var er: float = BodyView.real_display_radius(earth.radius_km, earth.mass_e)
	rig.apply_view(earth.display_pos, rig.yaw_goal, rig.pitch_goal, er * 3.0)
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/realscale_6_earth_closeup.png")

	# and a moon: Callisto's true disc is ~1e-4 display units across
	for mb: SimBody in sim.moons:
		if mb.body_name == "Callisto":
			Events.select_requested.emit(mb)
	await get_tree().create_timer(1.6).timeout
	var cal: SimBody = Events.selected
	var cr: float = BodyView.real_display_radius(cal.radius_km, cal.mass_e)
	rig.apply_view(cal.display_pos, rig.yaw_goal, rig.pitch_goal, cr * 3.0)
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/realscale_7_callisto_closeup.png")

	# True motion close-up on Jupiter: the drift-mode trail must hug the
	# planet without float32 jitter (verified over frames in-app; here we
	# check the line lands on the disc)
	Events.set_trail_mode(TrailFrames.MODE_TRUE)
	for b in sim.planets:
		if b.body_name == "Jupiter":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.6).timeout
	var jup: SimBody = Events.selected
	var jr: float = BodyView.real_display_radius(jup.radius_km, jup.mass_e)
	rig.apply_view(jup.display_pos, rig.yaw_goal, rig.pitch_goal, jr * 8.0)
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/realscale_8_jupiter_true_motion.png")

	# Sun-locked with "moon paths follow the frame": the Moon draws its true
	# wavy path around the Sun instead of a ring around Earth
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)
	Events.set_moon_trail_frame(true)
	for b in sim.planets:
		if b.body_name == "Earth":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.6).timeout
	var e2: SimBody = Events.selected
	rig.apply_view(e2.display_pos, rig.yaw_goal, rig.pitch_goal, 0.25)
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/realscale_9_moon_frame.png")
	Events.set_moon_trail_frame(false)

	# toggle back off: the familiar exaggerated orrery returns
	Events.deselect_requested.emit()
	rig.apply_view(Vector3.ZERO, rig.yaw_goal, rig.pitch_goal, 150.0)
	Events.set_real_scale(false)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/realscale_5_back_off.png")

	get_tree().quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual] saved ", path)
