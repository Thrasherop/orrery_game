extends Node
## Visual verification harness for the handheld experience: resizes the window
## to a phone shape, forces touch UI + a ~420 dpi content scale, boots the real
## main scene (which selects the MobileHud bottom-sheet paradigm), exercises
## the sheets and touch gestures and captures screenshots.
##   godot --path . res://tests/visual_phone.tscn


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
	var hud = main.hud
	var is_mobile: bool = hud is MobileHud
	print("[phone] mobile hud active: ", "ok" if is_mobile else "FAIL")
	await _shot("res://tests/phone_1_overview.png")

	# select Saturn → fly-to + the body sheet peeks above the action bar
	var sim: Simulation = main.sim
	for b in sim.planets:
		if b.body_name == "Saturn":
			Events.select_requested.emit(b)
	await get_tree().create_timer(1.5).timeout
	var peeked: bool = hud.body_sheet.is_open() and hud.body_sheet.state == MobileSheet.State.PEEK
	print("[phone] body sheet peeks on select: ", "ok" if peeked else "FAIL")
	await _shot("res://tests/phone_2_body_peek.png")

	# expand → full stats; collapsing back to peek keeps selection + follow
	hud.body_sheet.expand()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_2b_body_full.png")
	hud.body_sheet.collapse()
	await get_tree().create_timer(0.4).timeout
	var kept: bool = Events.selected != null
	print("[phone] collapsed sheet keeps selection: ", "ok" if kept else "FAIL")

	# planets sheet
	hud.planets_sheet.open_sheet()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_3_planets.png")
	hud.planets_sheet.close()
	await get_tree().create_timer(0.4).timeout

	# add-body sheet (the shared form, embedded)
	hud.open_add(null)
	await get_tree().create_timer(0.6).timeout
	# Cancel/Add are pinned as the sheet footer: on screen without scrolling
	var ar: Rect2 = hud.add_panel.actions_row.get_global_rect()
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var actions_reachable: bool = hud.add_panel.actions_row.is_visible_in_tree() \
		and ar.position.y >= 0.0 and ar.end.y <= vp.y
	print("[phone] add/cancel reachable without scrolling: ",
		"ok" if actions_reachable else "FAIL", "  rect=", ar)
	await _shot("res://tests/phone_4_add.png")

	# tuck the in-progress form down to its peek: progress must survive (only
	# Cancel/Add clear it) and the body card stays suppressed underneath
	hud.add_panel.name_edit.text = "Draft body"
	hud.add_sheet.collapse()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_4b_add_peek.png")
	var add_kept: bool = hud.add_sheet.is_open() and hud.add_panel.visible \
		and hud.add_panel.name_edit.text == "Draft body"
	print("[phone] tucked add form keeps progress: ", "ok" if add_kept else "FAIL")
	var footer_tucked: bool = not hud.add_panel.actions_row.is_visible_in_tree()
	print("[phone] footer hidden at peek: ", "ok" if footer_tucked else "FAIL")
	hud.add_sheet.expand()
	await get_tree().create_timer(0.4).timeout
	hud.add_panel.close_panel()
	await get_tree().create_timer(0.5).timeout
	var add_closed: bool = not hud.add_sheet.is_open()
	print("[phone] closing the form folds the sheet: ", "ok" if add_closed else "FAIL")
	var body_restored: bool = hud.body_sheet.visible and Events.selected != null
	print("[phone] body card restored after add: ", "ok" if body_restored else "FAIL")
	Events.deselect_requested.emit()

	# time, menu and settings sheets
	hud.time_sheet.open()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_5_time.png")
	hud.time_sheet.close()
	await get_tree().create_timer(0.3).timeout
	hud.menu_sheet.open_sheet()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_6_menu.png")
	hud.menu_sheet.close()
	await get_tree().create_timer(0.3).timeout
	hud.settings.open_panel()
	hud.settings_sheet.open()
	await get_tree().create_timer(0.5).timeout
	await _shot("res://tests/phone_7_settings.png")
	hud.settings_sheet.close()
	await get_tree().create_timer(0.3).timeout

	# save browser overlay (demo content is removed again after the shot)
	var browser: SaveBrowser = hud.save_browser
	var demo: String = browser.store.create_save("", "Demo experiment", Snapshot.capture(sim, main.camera_rig))
	var folder: String = browser.store.create_folder("", "Demos")
	browser.open_browser()
	await get_tree().create_timer(0.4).timeout
	await _shot("res://tests/phone_8_saves.png")
	browser.close_browser()
	browser.store.delete_save(demo)
	browser.store.delete_folder(folder)

	# --- gesture unit checks against the rig ------------------------------
	# return to the boot overview so Earth is on screen for the tap check
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
	await _shot("res://tests/phone_9_after_gestures.png")
	var all_ok := ok_out and ok_in and picked == "Earth" and kept and peeked \
		and actions_reachable and footer_tucked \
		and add_kept and add_closed and body_restored and is_mobile
	get_tree().quit(0 if all_ok else 1)


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
