class_name Hud
extends CanvasLayer
## Assembles all HUD panels, anchors them like the prototype's layout, and
## handles the global keyboard shortcuts.

var sim: Simulation

var brand: BrandPanel
var rail: RailPanel
var info: InfoCard
var dock: DockPanel
var add_panel: AddPanel
var toast: ToastLabel
var hint: Label

# every panel lives in a slide-away edge drawer (Samsung-edge-panel style)
var brand_drawer: EdgeDrawer
var rail_drawer: EdgeDrawer
var info_drawer: EdgeDrawer
var dock_drawer: EdgeDrawer


func setup(sim_: Simulation) -> void:
	sim = sim_
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
	rail.add_clicked.connect(add_panel.open_panel)

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
	if sim.physics_active:
		var g_tag := (" · G×%.2f" % sim.g_scale) if absf(sim.g_scale - 1.0) > 0.005 else ""
		brand.set_mode("N-body gravity" + g_tag, true)
	else:
		brand.set_mode("Kepler ephemeris", false)


func update_live() -> void:
	brand.update_clock(sim.sim_ms)
	info.update_live()
	dock.update_live()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
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
		KEY_ESCAPE:
			if add_panel.is_open():
				add_panel.close_panel()
			else:
				Events.deselect_requested.emit()
