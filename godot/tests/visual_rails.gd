extends Node
## Visual harness for the per-body simulation toggle + physics-load drawer.
## Saves rails_*.png and exits nonzero on failure.
##   godot --path godot res://tests/visual_rails.tscn

var _fails := 0


func _check(cond: bool, msg: String) -> void:
	print(("  ok  " if cond else "  FAIL ") + msg)
	if not cond:
		_fails += 1


func _ready() -> void:
	get_window().size = Vector2i(1600, 900)
	await get_tree().process_frame
	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	var sim: Simulation = main.sim
	if not sim.moons_simulated:
		sim.set_moons_simulated(true)

	# enter physics with a harmless far body so the load panel has content
	sim.add_custom_body({
		name = "Far", mass_e = 1.0, dist_au = 3.0,
		lon_deg = 120.0, lat_deg = 0.0, speed_kms = 17.2, dir_deg = 0.0,
	})
	main.hud.add_panel.close_panel()
	await get_tree().create_timer(1.0).timeout

	print("[visual_rails] physics-load drawer")
	main.hud.perf_drawer.set_open(true)
	await get_tree().create_timer(1.2).timeout   # one refresh cycle
	_check(main.hud.perf.get_node_or_null(".") != null, "perf panel exists")
	_check(main.hud.perf._rows_box.get_child_count() > 0, "load rows populated (Io & friends)")
	await _shot("res://tests/rails_1_load_panel.png")

	print("[visual_rails] info-card checkbox rails Io")
	var io: SimBody = null
	for b in sim.moons:
		if b.body_name == "Io":
			io = b
	Events.select_requested.emit(io)
	await get_tree().create_timer(1.5).timeout
	_check(main.hud.info.sim_check.visible, "Simulated checkbox shown for a moon")
	_check(main.hud.info.sim_check.button_pressed, "checkbox starts checked")
	await _shot("res://tests/rails_2_card_checked.png")
	main.hud.info.sim_check.set_pressed(false)   # real UI path → set_simulated
	await get_tree().create_timer(1.5).timeout
	_check(not io.simulated, "unchecking put Io on rails")
	_check(sim.nb.index_of(io) < 0, "Io left the integrator")
	var listed := false
	for c in sim.step_costs():
		if c.body == io:
			listed = true
	_check(not listed, "Io gone from the load list")
	await _shot("res://tests/rails_3_io_railed.png")

	print("[visual_rails] %s" % ("ALL PASSED" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[visual_rails] saved ", path)
