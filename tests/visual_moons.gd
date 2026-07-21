extends Node
## Visual verification harness for the moon update: boots the real main
## scene and captures the new moon UI/simulation surfaces.
##   godot --path godot res://tests/visual_moons.tscn


func _ready() -> void:
	get_window().size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout

	var sim: Simulation = main.sim
	if not sim.moons_simulated:
		sim.set_moons_simulated(true)

	# Earth close-up: the Moon as a real body with its display-space trail
	var earth: SimBody = null
	for b in sim.planets:
		if b.body_name == "Earth":
			earth = b
	Events.select_requested.emit(earth)
	sim.speed = 86400.0   # day/s — visible moon motion
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/moonshot_1_earth_moon.png")

	# rail dropdown: Jupiter expanded (what a long-press produces)
	var rail: RailPanel = main.hud.rail
	var jupiter: SimBody = null
	for b in sim.planets:
		if b.body_name == "Jupiter":
			jupiter = b
	rail._toggle_expanded(jupiter)
	Events.select_requested.emit(jupiter)
	await get_tree().create_timer(2.0).timeout
	await _shot("res://tests/moonshot_2_rail_moons.png")

	# settings panel (moon flags unlocked — still in Kepler mode)
	Events.deselect_requested.emit()
	main.hud.settings.open_panel()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/moonshot_3_settings.png")
	main.hud.settings.close_panel()

	# add-moon form + preview around Mars
	var mars: SimBody = null
	for b in sim.planets:
		if b.body_name == "Mars":
			mars = b
	Events.select_requested.emit(mars)
	await get_tree().create_timer(1.5).timeout
	main.hud.add_panel.open_panel(mars)
	await get_tree().create_timer(0.8).timeout
	await _shot("res://tests/moonshot_4_add_moon.png")

	# actually add it, then watch it orbit under live gravity
	main.hud.add_panel.add_btn.pressed.emit()
	sim.speed = 86400.0
	await get_tree().create_timer(2.5).timeout
	await _shot("res://tests/moonshot_5_new_moon.png")

	# settings again — now locked (physics mode)
	Events.deselect_requested.emit()
	main.hud.settings.open_panel()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/moonshot_6_settings_locked.png")
	main.hud.settings.close_panel()

	get_tree().quit(0)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual_moons] saved ", path)
