extends Node
## Headless test for the save system core (snapshot round-trip + SaveStore):
##   godot --headless --path godot res://tests/save_test.tscn

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok  ", msg)
	else:
		_failures += 1
		printerr("FAIL  ", msg)


func _ready() -> void:
	print("[save_test] snapshot capture/apply")
	_test_snapshot()
	print("[save_test] save store")
	_test_store()
	print("[save_test] save browser flows")
	_test_browser()
	print("[save_test] %s" % ("ALL PASSED" if _failures == 0 else "%d FAILURES" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _test_snapshot() -> void:
	var sim := Simulation.new()
	add_child(sim)
	var rig := CameraRig.new()
	add_child(rig)
	sim.tick(0.016)

	# build a diverged physics state: custom body + G tweak + some sim time
	var body := sim.add_custom_body({
		name = "Saver", mass_e = 800.0, dist_au = 3.0,
		lon_deg = 45.0, lat_deg = 10.0, speed_kms = 15.0, dir_deg = 20.0,
	})
	sim.set_g_scale(2.0)
	sim.speed = 604800.0
	for i in range(60 * 10):
		sim.tick(1.0 / 60.0)
	rig.apply_view(Vector3(3, 1, -2), 0.7, 0.3, 88.0)

	var earth := _planet(sim, "Earth")
	var ms0 := sim.sim_ms
	var earth_r0 := earth.r_au
	var body_r0 := body.r_au
	var snap := Snapshot.capture(sim, rig)
	_check(Snapshot.validate(snap), "captured snapshot validates")

	# full-precision JSON round trip
	var parsed = JSON.parse_string(JSON.stringify(snap, "", false, true))
	_check(typeof(parsed) == TYPE_DICTIONARY and Snapshot.validate(parsed),
		"snapshot survives JSON round trip")

	# diverge further, then restore
	for i in range(60 * 20):
		sim.tick(1.0 / 60.0)
	rig.apply_view(Vector3.ZERO, 0.0, 0.0, 300.0)
	_check(absf(sim.sim_ms - ms0) > 1.0, "sim diverged before restore")

	_check(Snapshot.apply(sim, rig, parsed), "apply() succeeds")
	_check(sim.sim_ms == ms0, "sim_ms restored exactly (Δ=%f)" % absf(sim.sim_ms - ms0))
	_check(sim.physics_active and sim.physics_permanent, "physics mode restored")
	_check(absf(sim.g_scale - 2.0) < 1e-12, "g_scale restored")
	_check(sim.customs.size() == 1, "custom body restored")
	var b2: SimBody = sim.customs[0]
	_check(b2.body_name == "Saver" and b2.mass_e == 800.0, "custom identity restored")
	_check(b2.color.to_html(false) == body.color.to_html(false), "custom color restored")
	_check(absf(b2.r_au - body_r0) < 1e-9, "custom position restored (Δ=%.12f)" % absf(b2.r_au - body_r0))
	var earth2 := _planet(sim, "Earth")
	_check(absf(earth2.r_au - earth_r0) < 1e-9, "Earth position restored (Δ=%.12f)" % absf(earth2.r_au - earth_r0))
	_check(rig.view_state().dist == 88.0 and rig.view_state().yaw == 0.7, "camera restored")

	# a snapshot without Mercury removes it; re-applying the full one restores it
	var no_mercury: Dictionary = JSON.parse_string(JSON.stringify(parsed, "", false, true))
	var kept: Array = []
	for e in no_mercury.planets:
		if e.name != "Mercury":
			kept.append(e)
	no_mercury.planets = kept
	_check(Snapshot.apply(sim, rig, no_mercury), "apply() without Mercury succeeds")
	_check(sim.planets.size() == 7 and _planet(sim, "Mercury") == null, "Mercury removed by snapshot diff")
	_check(Snapshot.apply(sim, rig, parsed), "re-apply full snapshot succeeds")
	_check(sim.planets.size() == 8 and _planet(sim, "Mercury") != null, "Mercury rebuilt from catalog")

	# Kepler-mode snapshot: reset, capture, diverge, restore
	_check(Snapshot.apply(sim, rig, Snapshot.default_snapshot()), "reset (default snapshot) applies")
	_check(not sim.physics_active and not sim.physics_permanent, "reset returns to Kepler mode")
	_check(sim.planets.size() == 8 and sim.customs.is_empty(), "reset restores pristine body set")
	_check(sim.g_scale == 1.0 and sim.custom_count == 0, "reset restores defaults")
	_check(_planet(sim, "Earth").trail_size() > 0, "planet trails backfilled after reset")

	var ksnap := Snapshot.capture(sim, rig)
	var kms := sim.sim_ms
	_check(not ksnap.planets[0].has("phys"), "Kepler snapshot carries no phys rows")
	for i in range(60 * 5):
		sim.tick(1.0 / 60.0)
	var kparsed = JSON.parse_string(JSON.stringify(ksnap, "", false, true))
	_check(Snapshot.apply(sim, rig, kparsed), "Kepler snapshot applies")
	_check(sim.sim_ms == kms and not sim.physics_active, "Kepler time restored exactly")

	# invalid data is refused without touching the sim
	var before := sim.sim_ms
	_check(not Snapshot.apply(sim, rig, { version = 99 }), "future version refused")
	_check(not Snapshot.apply(sim, rig, {}), "empty dict refused")
	_check(sim.sim_ms == before, "failed apply leaves sim untouched")

	sim.queue_free()
	rig.queue_free()


func _planet(sim: Simulation, name: String) -> SimBody:
	for b in sim.planets:
		if b.body_name == name:
			return b
	return null


func _test_store() -> void:
	var store := SaveStore.new()
	# scratch area — cleaned up at the end
	if DirAccess.dir_exists_absolute("user://saves/_test"):
		store.delete_folder("_test")
	var folder := store.create_folder("", "_test")
	_check(folder == "_test", "create_folder (got '%s')" % folder)

	var snap := Snapshot.default_snapshot()
	var p1 := store.create_save("_test", "Test One!", snap)
	_check(p1 == "_test/test-one.save.json", "create_save slugifies (got '%s')" % p1)
	var data := store.read_save(p1)
	_check(not data.is_empty() and data.meta.name == "Test One!", "read_save round-trips display name")
	_check(Snapshot.validate(data.current), "stored snapshot validates")
	_check(not FileAccess.file_exists("user://saves/" + p1 + ".tmp"), "no stale .tmp after write")

	var p2 := store.create_save("_test", "Test One!", snap)
	_check(p2 == "_test/test-one-2.save.json", "name collision auto-suffixes (got '%s')" % p2)

	var renamed := store.rename_save(p2, "Renamed Save")
	_check(renamed == "_test/renamed-save.save.json", "rename_save re-slugs (got '%s')" % renamed)
	_check(not FileAccess.file_exists("user://saves/" + p2), "old file removed on rename")
	_check(store.read_save(renamed).meta.name == "Renamed Save", "rename updates meta.name")

	var inner := store.create_folder("_test", "Inner Folder")
	_check(inner == "_test/Inner Folder", "nested folder keeps display name (got '%s')" % inner)
	var moved := store.move_save(renamed, inner)
	_check(moved == "_test/Inner Folder/renamed-save.save.json", "move_save (got '%s')" % moved)

	var dup := store.duplicate_save(moved, "Branch Copy")
	_check(dup == "_test/Inner Folder/branch-copy.save.json", "duplicate_save (got '%s')" % dup)
	_check(store.read_save(dup).meta.name == "Branch Copy", "duplicate carries new name")
	_check(not store.read_save(moved).is_empty(), "original untouched by duplicate")

	var listing := store.list_dir("_test")
	_check(listing.folders == ["_test/Inner Folder"], "list_dir folders")
	_check(listing.saves.size() == 1 and listing.saves[0].name == "Test One!", "list_dir saves")

	var hits := store.search("branch")
	_check(hits.size() == 1 and hits[0].path == dup and hits[0].folder == inner,
		"search finds nested save with folder")
	_check(store.search("no-such-name-xyz").is_empty(), "search misses cleanly")

	# corrupt file: unreadable but still listed (so the user can delete it)
	var cf := FileAccess.open("user://saves/_test/broken.save.json", FileAccess.WRITE)
	cf.store_string("{ not json !!!")
	cf.close()
	_check(store.read_save("_test/broken.save.json").is_empty(), "corrupt file reads as empty")
	var listing2 := store.list_dir("_test")
	var corrupt_listed := false
	for e in listing2.saves:
		if e.path == "_test/broken.save.json" and e.corrupt:
			corrupt_listed = true
	_check(corrupt_listed, "corrupt file listed as corrupt")

	_check(store.delete_save(p1), "delete_save")
	_check(store.read_save(p1).is_empty(), "deleted save gone")
	_check(store.delete_folder("_test"), "delete_folder recursive")
	_check(not DirAccess.dir_exists_absolute("user://saves/_test"), "scratch folder cleaned up")


func _test_browser() -> void:
	var sim := Simulation.new()
	add_child(sim)
	var rig := CameraRig.new()
	add_child(rig)
	sim.tick(0.016)
	var browser := SaveBrowser.new()
	browser.setup(sim, rig)
	add_child(browser)

	var store: SaveStore = browser.store
	if DirAccess.dir_exists_absolute("user://saves/_ui"):
		store.delete_folder("_ui")
	store.create_folder("", "_ui")
	browser._dir = "_ui"

	browser.open_browser()
	_check(browser.is_open(), "browser opens")

	# save-as through the inline name form
	browser._save_as()
	browser._name_edit.text = "UI Test"
	browser._name_form_ok()
	_check(browser.current_path == "_ui/ui-test.save.json",
		"save-as creates and loads (got '%s')" % browser.current_path)
	_check(not store.read_save(browser.current_path).is_empty(), "save-as file valid")

	# quick save after mutating the sim
	sim.add_custom_body({
		name = "UIbody", mass_e = 2.0, dist_au = 1.5,
		lon_deg = 0.0, lat_deg = 0.0, speed_kms = 24.0, dir_deg = 0.0,
	})
	browser.quick_save()
	var data := store.read_save(browser.current_path)
	_check(bool(data.current.sim.physics_active), "quick save captured the mutated state")

	# checkpoint appends to the history AND becomes current
	browser._create_checkpoint("before crash")
	data = store.read_save(browser.current_path)
	_check((data.checkpoints as Array).size() == 1
		and data.checkpoints[0].label == "before crash", "checkpoint appended with label")
	_check(int(data.next_checkpoint_id) == 2, "checkpoint id advanced")

	# load goes through a confirmation dialog
	Snapshot.apply(sim, rig, Snapshot.default_snapshot())
	_check(not sim.physics_active, "reset before load test")
	browser._confirm_load({ path = browser.current_path, name = "UI Test", corrupt = false })
	var dlg := _find_confirm(browser)
	_check(dlg != null, "load asks for confirmation")
	if dlg != null:
		dlg._answer(true)
	_check(sim.physics_active, "confirmed load applied the save")
	_check(not browser.is_open(), "load closes the browser")

	store.delete_folder("_ui")
	browser.queue_free()
	sim.queue_free()
	rig.queue_free()


func _find_confirm(node: Node) -> ConfirmPanel:
	for c in node.get_children():
		if c is ConfirmPanel:
			return c
	return null
