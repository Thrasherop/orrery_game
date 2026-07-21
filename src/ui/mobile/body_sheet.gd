class_name BodySheet
extends MobileSheet
## Mobile replacement for the desktop info card: a non-modal bottom sheet that
## peeks above the action bar when a body is selected (name + live distance /
## velocity) and expands to the full stat grid, mass slider, simulated toggle
## and remove button. Swiping it away (or ✕) deselects; the peek state keeps
## the selection and camera follow.

const PEEK_H := 128.0

var sim: Simulation

var type_label: Label
var name_label: Label
var live_label: Label
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
var sim_check: CheckButton
var remove_btn: Button
var _dot_style: StyleBoxFlat


func _init() -> void:
	super(false, PEEK_H)
	max_ratio = 0.72


func setup(sim_: Simulation) -> void:
	sim = sim_

	# --- peek region: header + live line -----------------------------------
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	content.add_child(head)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(12, 12)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot_style = StyleBoxFlat.new()
	_dot_style.bg_color = UITheme.ACCENT
	_dot_style.set_corner_radius_all(6)
	dot.add_theme_stylebox_override("panel", _dot_style)
	head.add_child(dot)
	var head_col := VBoxContainer.new()
	head_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_col.add_theme_constant_override("separation", 0)
	type_label = UITheme.make_key_label("Planet")
	type_label.add_theme_color_override("font_color", UITheme.ACCENT)
	head_col.add_child(type_label)
	name_label = UITheme.make_label("Earth", 19, UITheme.TEXT)
	head_col.add_child(name_label)
	head.add_child(head_col)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.tooltip_text = "Deselect"
	UITheme.style_chip(close_btn, 13)
	close_btn.custom_minimum_size = Vector2(44, 44)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	close_btn.pressed.connect(func() -> void: Events.deselect_requested.emit())
	head.add_child(close_btn)

	live_label = UITheme.make_label("—", 12, UITheme.MUTED)
	content.add_child(live_label)

	# --- expanded region ----------------------------------------------------
	desc_label = UITheme.make_label("", 12, UITheme.MUTED)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(desc_label)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	st_dist = _stat_cell(grid, "Distance")
	st_vel = _stat_cell(grid, "Velocity")
	var period_cell := _stat_cell_with_key(grid, "Orbit period")
	k_period = period_cell[0]
	st_period = period_cell[1]
	st_day = _stat_cell(grid, "Day length")
	st_radius = _stat_cell(grid, "Radius")
	st_tilt = _stat_cell(grid, "Axial tilt")
	content.add_child(grid)

	var me_row := HBoxContainer.new()
	var me_k := UITheme.make_key_label("Mass")
	me_k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me_row.add_child(me_k)
	mass_val = UITheme.make_label("1.00×", 11, UITheme.ACCENT)
	me_row.add_child(mass_val)
	content.add_child(me_row)
	mass_slider = HSlider.new()
	mass_slider.min_value = -200
	mass_slider.max_value = 400
	mass_slider.step = 1
	mass_slider.value = 0
	UITheme.style_slider(mass_slider)
	mass_slider.value_changed.connect(_on_mass_slider)
	content.add_child(mass_slider)

	sim_check = CheckButton.new()
	sim_check.text = "Simulated"
	sim_check.tooltip_text = "Off = on rails: glides on a fixed circular orbit, exerts and feels no gravity, can't collide — and stops costing physics steps"
	sim_check.focus_mode = Control.FOCUS_NONE
	sim_check.add_theme_font_size_override("font_size", UITheme.fs(12))
	sim_check.add_theme_color_override("font_color", UITheme.TEXT)
	sim_check.toggled.connect(_on_sim_toggled)
	sim_check.visible = false
	content.add_child(sim_check)

	remove_btn = Button.new()
	remove_btn.text = "Remove body"
	UITheme.style_danger(remove_btn)
	remove_btn.custom_minimum_size = Vector2(0, 44)
	remove_btn.visible = false
	remove_btn.pressed.connect(_on_remove)
	content.add_child(remove_btn)

	Events.selection_changed.connect(_on_selection_changed)
	# swiping the sheet away (below peek) is a deselect gesture
	closed.connect(func() -> void:
		if Events.selected != null:
			Events.deselect_requested.emit())


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
		close()
		return
	var b: SimBody = body
	_dot_style.bg_color = b.color
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
	sim_check.visible = b.custom or b.is_moon
	sim_check.set_pressed_no_signal(b.simulated)
	mass_slider.set_value_no_signal(roundf(100.0 * (log(b.mass_scale) / log(10.0)) if b.mass_scale > 0.0 else 0.0))
	_update_mass_readout(b)
	if not is_open():
		open()   # peek — expanding is the user's gesture
	update_live()


func update_live() -> void:
	var b = Events.selected
	if b == null or not is_open():
		return
	if b.is_sun:
		st_dist.text = "0 AU"
		st_vel.text = "—"
		live_label.text = "the system's anchor"
	else:
		st_dist.text = "%.3f AU" % b.r_au
		st_vel.text = "%.1f km/s" % b.vel_kms
		live_label.text = "%.3f AU · %.1f km/s" % [b.r_au, b.vel_kms]


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


func _on_sim_toggled(on: bool) -> void:
	var b = Events.selected
	if b == null:
		return
	sim.set_simulated(b, on)
	# reflect what the sim actually did (the toggle is a no-op for planets)
	sim_check.set_pressed_no_signal(b.simulated)


func _on_remove() -> void:
	var b = Events.selected
	if b == null or not b.custom:
		return
	if b.is_moon:
		sim.remove_moon(b)
	else:
		sim.remove_custom_body(b)
