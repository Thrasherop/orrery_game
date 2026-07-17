extends Node
## Visual verification harness for the handheld experience: resizes the window
## to a phone shape, forces touch UI + a ~420 dpi content scale, boots the real
## main scene, exercises the touch gestures and captures screenshots.
##   godot --path godot res://tests/visual_phone.tscn


func _ready() -> void:
	var win := get_window()
	win.size = Vector2i(2400, 1080)
	await get_tree().process_frame
	UX.scale_override = 2.0   # what a 420 dpi / 1080p phone would compute
	UX.set_simulated_handheld(true)
	print("[phone] touch=", UITheme.touch, " visible rect=", win.get_visible_rect())

	var main: Node = load("res://main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(3.0).timeout
	await _shot("res://tests/phone_1_overview.png")

	# select Saturn → fly-to + info card
	var sim: Simulation = main.sim
	for b in sim.planets:
		if b.body_name == "Saturn":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.5).timeout
	await _shot("res://tests/phone_2_info.png")

	# tuck the info card + rail into their edge drawers: only the tabs remain
	# and the selection (camera follow) must survive
	main.hud.info_drawer.set_open(false, false)
	main.hud.rail_drawer.set_open(false, false)
	await get_tree().create_timer(0.3).timeout
	var kept: bool = Events.selected != null
	print("[phone] minimized card keeps selection: ", "ok" if kept else "FAIL")
	await _shot("res://tests/phone_2b_drawers_tucked.png")
	main.hud.info_drawer.set_open(true, false)
	main.hud.rail_drawer.set_open(true, false)

	# add-body form
	main.hud.add_panel.open_panel()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_3_addpanel.png")
	main.hud.add_panel.close_panel()
	Events.deselect_requested.emit()

	# save browser overlay (demo content is removed again after the shot)
	var browser: SaveBrowser = main.hud.save_browser
	var demo: String = browser.store.create_save("", "Demo experiment", Snapshot.capture(sim, main.camera_rig))
	var folder: String = browser.store.create_folder("", "Demos")
	browser.open_browser()
	await get_tree().create_timer(0.4).timeout
	await _shot("res://tests/phone_5_saves.png")
	browser.close_browser()
	browser.store.delete_save(demo)
	browser.store.delete_folder(folder)

	# --- gesture unit checks against the rig ------------------------------
	# the add panel flew the camera to the proposed body's position — return
	# to the boot overview so Earth is on screen for the tap check below
	var rig: CameraRig = main.camera_rig
	rig.apply_view(Vector3.ZERO, 0.313, 0.379, 167.5)
	await get_tree().process_frame
	var d0: float = rig.dist_goal
	_pinch(rig, Vector2(500, 270), Vector2(700, 270), Vector2(560, 270), Vector2(640, 270))
	var ok_out := rig.dist_goal > d0 * 1.5
	print("[phone] pinch-in zooms out: %.1f -> %.1f  %s" % [d0, rig.dist_goal, "ok" if ok_out else "FAIL"])

	d0 = rig.dist_goal
	_pinch(rig, Vector2(560, 270), Vector2(640, 270), Vector2(460, 270), Vector2(740, 270))
	var ok_in := rig.dist_goal < d0 * 0.7
	print("[phone] pinch-out zooms in: %.1f -> %.1f  %s" % [d0, rig.dist_goal, "ok" if ok_in else "FAIL"])

	# fat-finger tap: 14 logical px off Earth's disc must still select it
	var earth: SimBody = null
	for b in sim.planets:
		if b.body_name == "Earth":
			earth = b
	var sp: Vector2 = rig.cam.unproject_position(earth.display_pos) + Vector2(14, 0)
	_touch(rig, 0, sp, true)
	_touch(rig, 0, sp, false)
	var picked: String = Events.selected.body_name if Events.selected != null else "<none>"
	print("[phone] tap near Earth selected: ", picked, "  ", "ok" if picked == "Earth" else "FAIL")

	await get_tree().create_timer(1.2).timeout
	await _shot("res://tests/phone_4_after_gestures.png")
	get_tree().quit(0 if ok_out and ok_in and picked == "Earth" and kept else 1)


func _pinch(rig: CameraRig, a0: Vector2, b0: Vector2, a1: Vector2, b1: Vector2) -> void:
	_touch(rig, 0, a0, true)
	_touch(rig, 1, b0, true)
	_drag(rig, 0, a0, a1)
	_drag(rig, 1, b0, b1)
	_touch(rig, 0, a1, false)
	_touch(rig, 1, b1, false)


func _touch(rig: CameraRig, idx: int, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = idx
	ev.position = pos
	ev.pressed = pressed
	rig.handle_gui_input(ev)


func _drag(rig: CameraRig, idx: int, from: Vector2, to: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = idx
	ev.position = to
	ev.relative = to - from
	rig.handle_gui_input(ev)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[phone] saved ", path)
