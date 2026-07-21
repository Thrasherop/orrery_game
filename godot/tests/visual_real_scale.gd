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

	# toggle back off: the familiar exaggerated orrery returns
	Events.set_real_scale(false)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/realscale_5_back_off.png")

	get_tree().quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual] saved ", path)
