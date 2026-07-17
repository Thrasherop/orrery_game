class_name Hud
extends CanvasLayer
## Assembles all HUD panels, anchors them like the prototype's layout, and
## handles the global keyboard shortcuts.

var sim: Simulation
var rig: CameraRig

var brand: BrandPanel
var rail: RailPanel
var info: InfoCard
var dock: DockPanel
var perf: PerfPanel
var add_panel: AddPanel
var save_browser: SaveBrowser
var settings: SettingsPanel
var toast: ToastLabel
var hint: Label

var _last_badge := ""
var _lag_toast_shown := false

# every panel lives in a slide-away edge drawer (Samsung-edge-panel style)
var brand_drawer: EdgeDrawer
var rail_drawer: EdgeDrawer
var info_drawer: EdgeDrawer
var dock_drawer: EdgeDrawer
var perf_drawer: EdgeDrawer


func setup(sim_: Simulation, rig_: CameraRig = null) -> void:
	sim = sim_
	rig = rig_
	layer = 3

	brand = BrandPanel.new()
	brand_drawer = EdgeDrawer.new(EdgeDrawer.Edge.TOP, brand, "Tuck the clock away")
	brand_drawer.set_anchors_preset(Control.PRESET_TOP_LEFT)
	brand_drawer.position = Vector2(20, 20)
	add_child(brand_drawer)

	rail = RailPanel.new()
	rail.setup(sim)
	rail_drawer = EdgeDrawer.new(EdgeDrawer.Edge.LEFT, rail, "Tuck the planet list away")
	rail_drawer.anchor_top = 0.5
	rail_drawer.anchor_bottom = 0.5
	rail_drawer.grow_vertical = Control.GROW_DIRECTION_BOTH
	rail_drawer.offset_left = 20
	add_child(rail_drawer)

	info = InfoCard.new()
	info.setup(sim)
	info_drawer = EdgeDrawer.new(EdgeDrawer.Edge.RIGHT, info, "Minimize the info card (keeps following)")
	info_drawer.anchor_left = 1.0
	info_drawer.anchor_right = 1.0
	info_drawer.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	info_drawer.offset_right = -20
	info_drawer.offset_top = 20
	info_drawer.visible = false
	add_child(info_drawer)
	# minimizing (the drawer tab) keeps the selection and camera follow;
	# the card only disappears entirely on deselect (its ✕, or Esc)
	Events.selection_changed.connect(func(body) -> void:
		info_drawer.visible = body != null)

	add_panel = AddPanel.new()
	add_panel.setup(sim)
	if UITheme.touch:
		# top-anchored so the (height-capped) form never slides under the dock
		add_panel.offset_top = 12
		add_panel.offset_left = 252
	else:
		add_panel.anchor_top = 0.5
		add_panel.anchor_bottom = 0.5
		add_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
		add_panel.offset_left = 220
	add_child(add_panel)
	# "Add body…" builds around the currently selected body (sun/none → a
	# free sun-orbiting body, anything else → a moon of the selection)
	rail.add_clicked.connect(func() -> void:
		var sel = Events.selected
		add_panel.open_panel(null if sel == null or sel.is_sun else sel))
	rail.add_moon_clicked.connect(func(planet: SimBody) -> void:
		add_panel.open_panel(planet))

	dock = DockPanel.new()
	dock.setup(sim)
	dock_drawer = EdgeDrawer.new(EdgeDrawer.Edge.BOTTOM, dock, "Tuck the time controls away")
	dock_drawer.anchor_left = 0.5
	dock_drawer.anchor_right = 0.5
	dock_drawer.anchor_top = 1.0
	dock_drawer.anchor_bottom = 1.0
	dock_drawer.grow_horizontal = Control.GROW_DIRECTION_BOTH
	dock_drawer.grow_vertical = Control.GROW_DIRECTION_BEGIN
	dock_drawer.offset_bottom = -10 if UITheme.touch else -22
	add_child(dock_drawer)

	# physics-load drawer, bottom-left, tucked away by default — pull it out
	# to see which bodies are slowing the integrator down
	perf = PerfPanel.new()
	perf.setup(sim)
	perf_drawer = EdgeDrawer.new(EdgeDrawer.Edge.LEFT, perf, "Physics load: what's slowing the simulation")
	perf_drawer.anchor_top = 1.0
	perf_drawer.anchor_bottom = 1.0
	perf_drawer.grow_vertical = Control.GROW_DIRECTION_BEGIN
	perf_drawer.offset_left = 20
	perf_drawer.offset_bottom = -84 if UITheme.touch else -22
	add_child(perf_drawer)
	perf_drawer.set_open(false, false)

	save_browser = SaveBrowser.new()
	save_browser.setup(sim, rig)
	add_child(save_browser)
	brand.saves_clicked.connect(func() -> void:
		add_panel.close_panel()
		save_browser.open_browser())
	brand.reset_clicked.connect(save_browser.do_reset)

	settings = SettingsPanel.new()
	settings.setup(sim)
	add_child(settings)
	brand.settings_clicked.connect(func() -> void:
		add_panel.close_panel()
		settings.open_panel())

	toast = ToastLabel.new()
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 24
	add_child(toast)

	var hint_text := "drag to orbit · scroll to zoom · click a planet to follow\nspace pause · O orbits · L labels · esc deselect"
	if UITheme.touch:
		hint_text = "drag to orbit · pinch to zoom · tap a planet to follow"
	hint = UITheme.make_label(
		hint_text,
		10, Color(139 / 255.0, 151 / 255.0, 171 / 255.0, 0.75))
	if UITheme.touch:
		# top-center (the bottom is the dock's), fading away after a while
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.anchor_left = 0.5
		hint.anchor_right = 0.5
		hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
		hint.offset_top = 8
	else:
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hint.anchor_left = 1.0
		hint.anchor_right = 1.0
		hint.anchor_top = 1.0
		hint.anchor_bottom = 1.0
		hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
		hint.offset_right = -22
		hint.offset_bottom = -26
	add_child(hint)
	if UITheme.touch:
		var tween := hint.create_tween()
		tween.tween_interval(8.0)
		tween.tween_property(hint, "modulate:a", 0.0, 1.5)

	Events.mode_changed.connect(_update_mode_badge)
	_update_mode_badge()


func _update_mode_badge() -> void:
	var text: String
	var gravity := sim.physics_active
	if gravity:
		var g_tag := (" · G×%.2f" % sim.g_scale) if absf(sim.g_scale - 1.0) > 0.005 else ""
		text = "N-body gravity" + g_tag
		# the substep budget couldn't keep up with the requested time speed —
		# the clock is honestly lagging; say so instead of silently slowing
		if sim.lag_ratio < 0.9:
			text += " · limited ×%.1f" % sim.lag_ratio
			if not _lag_toast_shown:
				_lag_toast_shown = true
				Events.toast_requested.emit("Moon physics limits time speed — clock running slower than requested")
	else:
		text = "Kepler ephemeris"
	if text != _last_badge:
		_last_badge = text
		brand.set_mode(text, gravity)


func update_live() -> void:
	brand.update_clock(sim.sim_ms)
	info.update_live()
	dock.update_live()
	settings.update_live()
	_update_mode_badge()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_S and key.ctrl_pressed:
		get_viewport().set_input_as_handled()
		if key.shift_pressed:
			save_browser.open_browser(true)   # save as…
		else:
			save_browser.quick_save()
		return
	match key.keycode:
		KEY_SPACE:
			dock.set_playing(not sim.playing)
		KEY_O:
			Events.set_show_orbits(not Events.show_orbits)
		KEY_L:
			Events.set_show_labels(not Events.show_labels)
		KEY_V:
			Events.set_show_vectors(not Events.show_vectors)
		KEY_P:
			var next := (TrailFrames.mode + 1) % TrailFrames.MODE_NAMES.size()
			Events.set_trail_mode(next)
			Events.toast_requested.emit("Path frame: %s" % TrailFrames.MODE_NAMES[next])
		KEY_ESCAPE:
			if save_browser.is_open():
				save_browser.close_browser()
			elif settings.is_open():
				settings.close_panel()
			elif add_panel.is_open():
				add_panel.close_panel()
			else:
				Events.deselect_requested.emit()
