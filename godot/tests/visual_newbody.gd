extends Node
## Visual harness for the "new body" update: the rail's Add body… targets the
## selected body, the preview ring tilts with latitude, and the camera frames
## the proposed position. Saves newbody_*.png and exits nonzero on failure.
##   godot --path godot res://tests/visual_newbody.tscn

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
	var rig: CameraRig = main.camera_rig
	var panel: AddPanel = main.hud.add_panel
	var preview: AddPreview = main.world.preview

	print("[newbody] sun-relative flow")
	# no selection → rail's Add body… opens the sun-relative form
	main.hud.rail.add_clicked.emit()
	await get_tree().create_timer(0.3).timeout
	_check(panel.is_open() and panel.host == null, "no selection → sun-relative form")
	_check(rig.preview_focus_active(), "camera enters preview focus")
	# camera flies to the proposed position
	await get_tree().create_timer(1.2).timeout
	var fp = preview.focus_position()
	_check(fp != null and rig.target.distance_to(fp) < 1.0,
			"camera target reached the proposed position (off by %.2f)" % rig.target.distance_to(fp))
	await _shot("res://tests/newbody_1_default.png")

	# latitude tilts the guide ring through the injection point
	panel.lat_slider.value = 40.0
	await get_tree().create_timer(0.8).timeout
	var ring_y: Vector3 = preview._ring.basis.y.normalized()
	_check(absf(ring_y.dot(Vector3.UP)) < 0.999, "ring tilts out of the ecliptic at lat 40°")
	var to_sphere: Vector3 = preview._sphere.position
	_check(absf(to_sphere.normalized().dot(ring_y)) < 0.02,
			"ring plane passes through the injection point")
	_check(absf(to_sphere.length() - preview._ring.basis.x.length()) < 0.05,
			"ring radius matches the injection distance")
	await _shot("res://tests/newbody_2_lat40.png")

	# longitude swings the tilted ring around with the point
	panel.lon_slider.value = 200.0
	await get_tree().create_timer(0.8).timeout
	var ts2: Vector3 = preview._sphere.position
	_check(absf(ts2.normalized().dot(preview._ring.basis.y.normalized())) < 0.02,
			"ring keeps passing through the point after a longitude change")
	await _shot("res://tests/newbody_3_lon200.png")

	# cancel: preview focus released
	panel.close_panel()
	await get_tree().create_timer(0.3).timeout
	_check(not rig.preview_focus_active(), "cancel releases the preview focus")

	print("[newbody] selected-body (moon) flow")
	var mars: SimBody = null
	for b in sim.planets:
		if b.body_name == "Mars":
			mars = b
	Events.select_requested.emit(mars)
	await get_tree().create_timer(1.5).timeout
	main.hud.rail.add_clicked.emit()
	await get_tree().create_timer(0.3).timeout
	_check(panel.is_open() and panel.host == mars, "Mars selected → form hosts Mars")
	_check(panel.title_label.text.contains("Mars"), "panel titled for Mars")
	# circular speed preset is host-mass based, not the sun's ~18 km/s
	var v := panel.speed_edit.text.to_float()
	var want := sim.circ_speed_kms(panel.read_inputs().dist_au, mars)
	_check(absf(v - want) < 0.1 and v < 3.0,
			"preset speed is Mars-circular (%.2f km/s, want %.2f)" % [v, want])
	await get_tree().create_timer(1.0).timeout
	var fp2 = preview.focus_position()
	_check(fp2 != null and rig.target.distance_to(fp2) < 1.0,
			"camera framed the proposed moon (off by %.2f)" % rig.target.distance_to(fp2))
	await _shot("res://tests/newbody_4_mars_moon.png")

	# add it — the camera should end up following the real new moon
	panel.add_btn.pressed.emit()
	await get_tree().create_timer(1.5).timeout
	_check(not rig.preview_focus_active(), "adding releases the preview focus")
	var moon: SimBody = sim.moons.back() if not sim.moons.is_empty() else null
	_check(moon != null and moon.host == mars, "new moon lives under Mars")
	_check(Events.selected == moon, "new moon is selected")
	if moon != null:
		_check(rig.target.distance_to(moon.display_pos) < 1.0, "camera follows the new moon")
	await _shot("res://tests/newbody_5_added.png")

	print("[newbody] %s" % ("ALL PASSED" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[newbody] saved ", path)
