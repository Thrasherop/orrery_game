class_name InfoCard
extends PanelContainer
## Top-right info card: type/name/description, six live stats, the mass
## slider (0.01× – 10,000×, log) and the remove button for custom bodies.

var sim: Simulation

var type_label: Label
var name_label: Label
var desc_label: Label
var st_dist: Label
var st_vel: Label
var k_period: Label
var st_period: Label
var st_day: Label
var st_radius: Label
var st_tilt: Label
var mass_val: Label
var mass_slider: HSlider
var remove_btn: Button


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.panel_style())
	custom_minimum_size = Vector2(292, 0)
	# visibility is owned by the EdgeDrawer wrapping this card (see hud.gd)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var head := HBoxContainer.new()
	var head_col := VBoxContainer.new()
	head_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	type_label = UITheme.make_key_label("Planet")
	type_label.add_theme_color_override("font_color", UITheme.ACCENT)
	head_col.add_child(type_label)
	name_label = UITheme.make_label("Earth", 26, UITheme.TEXT)
	head_col.add_child(name_label)
	head.add_child(head_col)
	var close := Button.new()
	close.text = "✕"
	close.tooltip_text = "Deselect"
	UITheme.style_chip(close, 13)
	if UITheme.touch:
		close.custom_minimum_size = Vector2(44, 44)
	close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close.pressed.connect(func() -> void: Events.deselect_requested.emit())
	head.add_child(close)
	box.add_child(head)

	desc_label = UITheme.make_label("", 12, UITheme.MUTED)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.custom_minimum_size = Vector2(250, 0)
	box.add_child(desc_label)

	box.add_child(_spacer(8))

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	st_dist = _stat_cell(grid, "Distance")
	st_vel = _stat_cell(grid, "Velocity")
	var period_cell := _stat_cell_with_key(grid, "Orbit period")
	k_period = period_cell[0]
	st_period = period_cell[1]
	st_day = _stat_cell(grid, "Day length")
	st_radius = _stat_cell(grid, "Radius")
	st_tilt = _stat_cell(grid, "Axial tilt")
	box.add_child(grid)

	box.add_child(_spacer(10))

	# mass editing (switches the system to N-body gravity)
	var me_row := HBoxContainer.new()
	var me_k := UITheme.make_key_label("Mass")
	me_k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me_row.add_child(me_k)
	mass_val = UITheme.make_label("1.00×", 11, UITheme.ACCENT)
	me_row.add_child(mass_val)
	box.add_child(me_row)
	mass_slider = HSlider.new()
	mass_slider.min_value = -200
	mass_slider.max_value = 400
	mass_slider.step = 1
	mass_slider.value = 0
	UITheme.style_slider(mass_slider)
	mass_slider.value_changed.connect(_on_mass_slider)
	box.add_child(mass_slider)

	remove_btn = Button.new()
	remove_btn.text = "Remove body"
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.add_theme_font_size_override("font_size", UITheme.fs(11))
	var rsb := UITheme.flat_style(Color(1, 96 / 255.0, 96 / 255.0, 0.1), 9)
	rsb.border_color = Color(1, 120 / 255.0, 120 / 255.0, 0.28)
	rsb.set_border_width_all(1)
	remove_btn.add_theme_stylebox_override("normal", rsb)
	remove_btn.add_theme_stylebox_override("hover", UITheme.flat_style(Color(1, 96 / 255.0, 96 / 255.0, 0.2), 9))
	remove_btn.add_theme_color_override("font_color", Color("ff9d9d"))
	remove_btn.add_theme_color_override("font_hover_color", Color("ff9d9d"))
	remove_btn.visible = false
	remove_btn.pressed.connect(_on_remove)
	box.add_child(remove_btn)

	Events.selection_changed.connect(_on_selection_changed)


func _spacer(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _stat_cell(grid: GridContainer, key: String) -> Label:
	return _stat_cell_with_key(grid, key)[1]


func _stat_cell_with_key(grid: GridContainer, key: String) -> Array:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 2)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var k := UITheme.make_key_label(key)
	k.add_theme_font_size_override("font_size", UITheme.fs(9))
	cell.add_child(k)
	var v := UITheme.make_label("—", 13, UITheme.TEXT)
	cell.add_child(v)
	grid.add_child(cell)
	return [k, v]


func _on_selection_changed(body) -> void:
	if body == null:
		return
	var b: SimBody = body
	type_label.text = b.body_type.to_upper()
	name_label.text = b.body_name
	desc_label.text = b.desc
	if b.custom:
		k_period.text = "MASS"
		st_period.text = ("%s M⊕" % Fmt.fmt_big(roundf(b.mass_e))) if b.mass_e >= 1000.0 else ("%s M⊕" % b.mass_e)
		st_day.text = "—"
		st_radius.text = "—"
		st_tilt.text = "—"
	else:
		k_period.text = "ORBIT PERIOD"
		if b.period_days <= 0.0:
			st_period.text = "—"
		elif b.period_days > 900.0:
			st_period.text = "%.1f yr" % (b.period_days / 365.25)
		else:
			st_period.text = "%.1f d" % b.period_days
		var dh := absf(b.day_hours)
		var retro := " ↺" if b.day_hours < 0.0 else ""
		st_day.text = ("%.1f d%s" % [dh / 24.0, retro]) if dh > 48.0 else ("%.1f h%s" % [dh, retro])
		st_radius.text = "%s km" % Fmt.fmt_big(b.radius_km)
		st_tilt.text = "%.1f°" % b.tilt
	remove_btn.visible = b.custom
	mass_slider.set_value_no_signal(roundf(100.0 * (log(b.mass_scale) / log(10.0)) if b.mass_scale > 0.0 else 0.0))
	_update_mass_readout(b)


func update_live() -> void:
	var b = Events.selected
	if b == null:
		return
	if b.is_sun:
		st_dist.text = "0 AU"
		st_vel.text = "—"
	else:
		st_dist.text = "%.3f AU" % b.r_au
		st_vel.text = "%.1f km/s" % b.vel_kms


func _update_mass_readout(b: SimBody) -> void:
	var scale_ := b.mass_scale
	var earths := (sim.base_mass_of(b) * scale_) / Units.EARTH_SOLAR
	var e_txt := Fmt.fmt_big(roundf(earths)) if earths >= 100.0 else ("%.2f" % earths)
	var s_txt := ("%.2f" % scale_) if scale_ < 10.0 else Fmt.fmt_big(roundf(scale_))
	mass_val.text = "%s× · %s M⊕" % [s_txt, e_txt]


func _on_mass_slider(value: float) -> void:
	var b = Events.selected
	if b == null:
		return
	var mult := pow(10.0, value / 100.0)   # 0.01× – 10,000×
	sim.set_mass_scale(b, mult)
	_update_mass_readout(b)


func _on_remove() -> void:
	var b = Events.selected
	if b != null and b.custom:
		sim.remove_custom_body(b)
