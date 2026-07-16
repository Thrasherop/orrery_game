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


func setup(sim_: Simulation) -> void:
	sim = sim_
	layer = 3

	brand = BrandPanel.new()
	brand.set_anchors_preset(Control.PRESET_TOP_LEFT)
	brand.position = Vector2(20, 20)
	add_child(brand)

	rail = RailPanel.new()
	rail.setup(sim)
	rail.anchor_top = 0.5
	rail.anchor_bottom = 0.5
	rail.grow_vertical = Control.GROW_DIRECTION_BOTH
	rail.offset_left = 20
	add_child(rail)

	info = InfoCard.new()
	info.setup(sim)
	info.anchor_left = 1.0
	info.anchor_right = 1.0
	info.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	info.offset_right = -20
	info.offset_top = 20
	add_child(info)

	add_panel = AddPanel.new()
	add_panel.setup(sim)
	add_panel.anchor_top = 0.5
	add_panel.anchor_bottom = 0.5
	add_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_panel.offset_left = 196
	add_child(add_panel)
	rail.add_clicked.connect(add_panel.open_panel)

	dock = DockPanel.new()
	dock.setup(sim)
	dock.anchor_left = 0.5
	dock.anchor_right = 0.5
	dock.anchor_top = 1.0
	dock.anchor_bottom = 1.0
	dock.grow_horizontal = Control.GROW_DIRECTION_BOTH
	dock.grow_vertical = Control.GROW_DIRECTION_BEGIN
	dock.offset_bottom = -22
	add_child(dock)

	toast = ToastLabel.new()
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 24
	add_child(toast)

	hint = UITheme.make_label(
		"drag to orbit · scroll to zoom · click a planet to follow\nspace pause · O orbits · L labels · esc deselect",
		10, Color(139 / 255.0, 151 / 255.0, 171 / 255.0, 0.75))
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
