class_name RailPanel
extends PanelContainer
## Left planet rail: one button per body (colored dot + name) plus "Add body…".

signal add_clicked

var sim: Simulation
var _box: VBoxContainer
var _buttons := {}   # SimBody -> Button


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.panel_style(16, 8))
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 2)
	add_child(_box)
	rebuild()
	Events.bodies_changed.connect(rebuild)
	Events.selection_changed.connect(_on_selection_changed)


func rebuild() -> void:
	for c in _box.get_children():
		c.queue_free()
	_buttons.clear()

	for b in sim.all_bodies():
		var btn := _make_item(b.body_name, b.color)
		btn.pressed.connect(func() -> void: Events.select_requested.emit(b))
		_box.add_child(btn)
		_buttons[b] = btn

	var add_btn := _make_item("Add body…", UITheme.ACCENT)
	var add_lbl: Label = add_btn.get_meta("name_label")
	add_lbl.add_theme_color_override("font_color", UITheme.ACCENT)
	add_btn.pressed.connect(func() -> void: add_clicked.emit())
	_box.add_child(add_btn)
	_on_selection_changed(Events.selected)


func _make_item(text: String, dot_color: Color) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(150, 30)
	btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(0, 0, 0, 0)))
	btn.add_theme_stylebox_override("hover", UITheme.flat_style(Color(1, 1, 1, 0.06)))
	btn.add_theme_stylebox_override("pressed", UITheme.flat_style(Color(1, 1, 1, 0.08)))

	# content row overlaid on the button (colored dot + name)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 9
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = dot_color
	dsb.set_corner_radius_all(4)
	dot.add_theme_stylebox_override("panel", dsb)
	row.add_child(dot)
	var lbl := UITheme.make_label(text, 12, UITheme.MUTED)
	lbl.name = "NameLabel"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	btn.add_child(row)
	btn.set_meta("name_label", lbl)
	return btn


func _on_selection_changed(body) -> void:
	for b in _buttons:
		var btn: Button = _buttons[b]
		var lbl: Label = btn.get_meta("name_label")
		if b == body:
			btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.13)))
			lbl.add_theme_color_override("font_color", UITheme.TEXT)
		else:
			btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(0, 0, 0, 0)))
			lbl.add_theme_color_override("font_color", UITheme.MUTED)
