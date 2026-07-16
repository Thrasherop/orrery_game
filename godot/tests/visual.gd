extends Node
## Visual verification harness: boots the real main scene, captures
## screenshots at a few interesting moments, then quits.
##   godot --path godot res://tests/visual.tscn


func _ready() -> void:
	# explicit size: the OS may clamp the startup window, which would skew shots
	get_window().size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/shot_1_overview.png")

	# select Saturn → camera fly-to + info card
	var sim: Simulation = main.sim
	for b in sim.planets:
		if b.body_name == "Saturn":
			Events.select_requested.emit(b)
	await get_tree().create_timer(2.0).timeout
	await _shot("res://tests/shot_2_saturn.png")

	# open the add panel with a preview
	main.hud.add_panel.open_panel()
	Events.deselect_requested.emit()
	await get_tree().create_timer(1.0).timeout
	await _shot("res://tests/shot_3_addpanel.png")

	# inject a heavy body and let it wreak havoc at high speed
	main.hud.add_panel.close_panel()
	sim.add_custom_body({
		name = "Rogue", mass_e = 50000.0, dist_au = 3.0,
		lon_deg = 45.0, lat_deg = 10.0, speed_kms = 12.0, dir_deg = 20.0,
	})
	sim.speed = 2629800.0
	await get_tree().create_timer(4.0).timeout
	await _shot("res://tests/shot_4_nbody.png")

	# Venus info card (retrograde ↺ glyph check)
	for b in sim.planets:
		if b.body_name == "Venus":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/shot_5_venus.png")

	# impact flash + debris: clear the rogue, then drop a body into the sun
	Events.deselect_requested.emit()
	while not sim.customs.is_empty():
		sim.remove_custom_body(sim.customs[0])
	# lambdas capture locals by value — use a container so the write is visible
	var merged := [false]
	Events.merged.connect(func(_s, _l, _p, _c, _sc) -> void: merged[0] = true)
	sim.add_custom_body({
		name = "Bullet", mass_e = 80.0, dist_au = 0.4,
		lon_deg = 200.0, lat_deg = 0.0, speed_kms = 0.0, dir_deg = 0.0,
	})
	Events.deselect_requested.emit()
	sim.speed = 604800.0   # ~30-day free fall ≈ 4 s real time
	for i in 900:
		await get_tree().process_frame
		if merged[0]:
			break
	await get_tree().create_timer(0.15).timeout
	await _shot("res://tests/shot_6_impact.png")
	print("[visual] merged = ", merged[0])

	get_tree().quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual] saved ", path)
