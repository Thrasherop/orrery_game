extends Node
## Visual harness for the trail reference-frame system: reproduces the old
## failure case (a second sun dragging the barycenter/display frame around)
## and captures every path-frame mode, plus a mid-run mode-switch to prove
## switching is fluid (no reset, trails stay glued to their bodies).
##   godot --path godot res://tests/visual_trails.tscn


func _ready() -> void:
	get_window().size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(2.5).timeout

	var sim: Simulation = main.sim
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)

	# the killer scenario: a second sun in a close mutual orbit — under the
	# old absolute-space trails this made every orbit ring drift off its
	# planet and planets appear to spiral around nothingness
	sim.add_custom_body({
		name = "Twin Sun", mass_e = 250000.0, dist_au = 4.0,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 14.0, dir_deg = 0.0,
	})
	Events.deselect_requested.emit()
	sim.speed = 2629800.0   # 1 month/s: the frame visibly swings
	await get_tree().create_timer(6.0).timeout
	await _shot("res://tests/trail_1_local_twin_sun.png")

	# switch modes live mid-flight — nothing may reset or jump off-body
	Events.set_trail_mode(TrailFrames.MODE_INERTIAL)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/trail_2_inertial_wobble.png")

	Events.set_trail_mode(TrailFrames.MODE_GALAXY)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/trail_3_galaxy_helix.png")

	# real-space (barycentric): the twin suns swing around the barycenter as
	# separate bodies and outer planets draw smooth arcs — no sun-anchored kink
	Events.set_trail_mode(TrailFrames.MODE_TRUE)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/trail_3b_real_space.png")

	# focus frame on Earth: other planets should trace loops around it
	var earth: SimBody = null
	for b in sim.planets:
		if b.body_name == "Earth":
			earth = b
	Events.set_trail_mode(TrailFrames.MODE_FOCUS)
	Events.select_requested.emit(earth)
	await get_tree().create_timer(4.0).timeout
	await _shot("res://tests/trail_4_focus_earth.png")

	# back to local: rings must be intact (lossless switching)
	Events.deselect_requested.emit()
	Events.set_trail_mode(TrailFrames.MODE_LOCAL)
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/trail_5_local_back.png")

	# settings panel with the new Path frame chips
	main.hud.settings.open_panel()
	await get_tree().create_timer(0.4).timeout
	await _shot("res://tests/trail_6_settings.png")

	get_tree().quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual] saved ", path)
