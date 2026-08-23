class_name AddPanel
extends PanelContainer
## "New celestial body" form: name, mass, distance (log slider), longitude,
## latitude, speed, direction — with a live hint (circular/escape speeds) and
## a live 3D preview driven through Events.add_preview_changed.
## With a host body (open_panel(host) — the rail passes the currently
## selected body, so "Add body…" builds around whatever is in focus) the
## same form places a new MOON: inputs become host-relative, distance
## switches to 10⁻³ AU.

var sim: Simulation
var host: SimBody = null   # null = sun-relative custom body

## set BEFORE setup(): the panel drops its own chrome (panel style, height-cap
## scroll) because a MobileSheet hosts it and provides both. The Cancel/Add
## row is then not added to the form — it's exposed as `actions_row` for the
## host to pin as an always-reachable sheet footer.
var embedded := false
var actions_row: HBoxContainer = null

var title_label: Label
var name_edit: LineEdit
var mass_edit: LineEdit
var dist_edit: LineEdit
var dist_key: Label
var dist_slider: HSlider
var lon_slider: HSlider
var lon_val: Label
var lat_slider: HSlider
var lat_val: Label
var speed_edit: LineEdit
var dir_slider: HSlider
var dir_val: Label
var hint_label: Label
var add_btn: Button

var _moon_count := 0   # for default moon names

var _scroll: ScrollContainer


func setup(sim_: Simulation) -> void:
	sim = sim_
	if embedded:
		add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		add_theme_stylebox_override("panel", UITheme.panel_style())
		custom_minimum_size = Vector2(288, 0)
	visible = false

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	if UITheme.touch and not embedded:
		# touch: the form scrolls inside a height cap so it never slides
		# under the dock (see _update_size_cap); desktop fits as-is
		_scroll = ScrollContainer.new()
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.follow_focus = true
		add_child(_scroll)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.add_child(box)
	else:
		add_child(box)

	title_label = UITheme.make_label("New celestial body", 15, UITheme.TEXT)
	box.add_child(title_label)

	name_edit = _line_edit("Planet X")
	box.add_child(_form_row("Name", name_edit))
	mass_edit = _line_edit("1")
	box.add_child(_form_row("Mass M⊕", mass_edit))
	dist_edit = _line_edit("2.0")
	var dist_row := _form_row("Distance AU", dist_edit)
	dist_key = dist_row.get_child(0)
	box.add_child(dist_row)

	dist_slider = HSlider.new()
	dist_slider.min_value = 0
	dist_slider.max_value = 1000
	dist_slider.step = 1
	dist_slider.value = 500
	UITheme.style_slider(dist_slider)
	dist_slider.custom_minimum_size = Vector2(250, 30) if UITheme.touch else Vector2(250, 16)
	dist_slider.value_changed.connect(func(v: float) -> void:
		dist_edit.text = "%.2f" % (Fmt.slider_to_moon_dist(v) if host != null else Fmt.slider_to_dist(v))
		_on_input_changed())
	box.add_child(dist_slider)

	lon_val = UITheme.make_label("90°", 10, UITheme.ACCENT)
	lon_slider = _deg_slider(0, 360, 90)
	box.add_child(_slider_row("Longitude", lon_val, lon_slider))
	lat_val = UITheme.make_label("0° ecliptic", 10, UITheme.ACCENT)
	lat_slider = _deg_slider(-80, 80, 0)
	box.add_child(_slider_row("Latitude", lat_val, lat_slider))

	speed_edit = _line_edit("21.1")
	box.add_child(_form_row("Speed km/s", speed_edit))

	dir_val = UITheme.make_label("0° prograde", 10, UITheme.ACCENT)
	dir_slider = _deg_slider(-180, 180, 0)
	box.add_child(_slider_row("Direction", dir_val, dir_slider))

	hint_label = UITheme.make_label("—", 10, UITheme.MUTED)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint_label)

	var circ_btn := Button.new()
	circ_btn.text = "Set circular-orbit speed"
	UITheme.style_chip(circ_btn, 11)
	circ_btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(1, 1, 1, 0.06)))
	circ_btn.pressed.connect(func() -> void:
		speed_edit.text = "%.1f" % sim.circ_speed_kms(read_inputs().dist_au, host)
		_on_input_changed())
	box.add_child(circ_btn)

	var note := UITheme.make_label(
		"Adding a body switches the whole system to live N-body gravity — the arrow shows its starting velocity vector.",
		10, UITheme.ACCENT_WARM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate.a = 0.85
	box.add_child(note)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_ghost(cancel)
	cancel.pressed.connect(close_panel)
	actions.add_child(cancel)
	add_btn = Button.new()
	add_btn.text = "Add body"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_primary(add_btn)
	add_btn.pressed.connect(func() -> void:
		if host != null:
			_moon_count += 1
		sim.add_custom_body(read_inputs())
		close_panel())
	actions.add_child(add_btn)
	if embedded:
		actions_row = actions
	else:
		box.add_child(actions)

	for e in [name_edit, mass_edit, speed_edit]:
		e.text_changed.connect(func(_t: String) -> void: _on_input_changed())
	dist_edit.text_changed.connect(func(_t: String) -> void:
		var d := _parse(dist_edit.text, 2.0)
		dist_slider.set_value_no_signal(Fmt.moon_dist_to_slider(d) if host != null else Fmt.dist_to_slider(d))
		_on_input_changed())
	for s in [lon_slider, lat_slider, dir_slider]:
		s.value_changed.connect(func(_v: float) -> void: _on_input_changed())


func _ready() -> void:
	if _scroll == null:
		return
	get_viewport().size_changed.connect(_update_size_cap)
	_update_size_cap()


## touch only: cap the form to the space above the dock (the panel is
## top-anchored there); width comes from the form's own minimum
func _update_size_cap() -> void:
	if not is_inside_tree():
		return
	var need := (_scroll.get_child(0) as Control).get_combined_minimum_size()
	_scroll.custom_minimum_size = Vector2(need.x + 6, get_viewport_rect().size.y - 200.0)


func _line_edit(initial: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = initial
	e.custom_minimum_size = Vector2(130, 38) if UITheme.touch else Vector2(120, 0)
	e.add_theme_font_size_override("font_size", UITheme.fs(12))
	return e


func _form_row(key: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var k := UITheme.make_key_label(key)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(k)
	row.add_child(control)
	return row


func _slider_row(key: String, val: Label, slider: HSlider) -> HBoxContainer:
	var row := HBoxContainer.new()
	var col := HBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_child(UITheme.make_key_label(key))
	col.add_child(val)
	row.add_child(col)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	return row


func _deg_slider(minv: float, maxv: float, val: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = minv
	s.max_value = maxv
	s.step = 1
	s.value = val
	UITheme.style_slider(s)
	return s


static func _parse(text: String, fallback: float) -> float:
	var v := text.strip_edges().to_float()
	if v == 0.0 and not text.strip_edges().begins_with("0"):
		return fallback
	return v


func read_inputs() -> Dictionary:
	var dist_au: float
	if host != null:
		# the form works in 10⁻³ AU around a planet
		dist_au = clampf(_parse(dist_edit.text, 2.6), 0.5, 30.0) * 1e-3
	else:
		dist_au = clampf(_parse(dist_edit.text, 2.0), 0.08, 60.0)
	return {
		name = name_edit.text.strip_edges(),
		mass_e = clampf(_parse(mass_edit.text, 1.0), 0.0001, 5.0 if host != null else 4e6),
		dist_au = dist_au,
		lon_deg = lon_slider.value,
		lat_deg = lat_slider.value,
		speed_kms = maxf(_parse(speed_edit.text, 0.0), 0.0),
		dir_deg = dir_slider.value,
		host = host,
	}


func open_panel(host_: SimBody = null) -> void:
	host = host_
	if host != null:
		title_label.text = "New moon of %s" % host.body_name
		dist_key.text = "DISTANCE 10⁻³ AU"
		add_btn.text = "Add moon"
		name_edit.text = "Moon %d" % (_moon_count + 1)
		mass_edit.text = "0.01"
		dist_edit.text = "2.6"
		dist_slider.set_value_no_signal(Fmt.moon_dist_to_slider(2.6))
	else:
		title_label.text = "New celestial body"
		dist_key.text = "DISTANCE AU"
		add_btn.text = "Add body"
		name_edit.text = "Body %d" % (sim.custom_count + 1)
		mass_edit.text = "1"
		dist_edit.text = "2.0"
		dist_slider.set_value_no_signal(Fmt.dist_to_slider(2.0))
	speed_edit.text = "%.1f" % sim.circ_speed_kms(read_inputs().dist_au, host)
	visible = true
	_on_input_changed()


func close_panel() -> void:
	visible = false
	Events.add_preview_changed.emit(null)


func is_open() -> bool:
	return visible


func _on_input_changed() -> void:
	if not visible:
		return
	var cfg := read_inputs()
	lon_val.text = "%d°" % int(cfg.lon_deg)
	lat_val.text = "0° ecliptic" if cfg.lat_deg == 0.0 else "%d°" % int(cfg.lat_deg)
	dir_val.text = "0° prograde" if cfg.dir_deg == 0.0 else "%d°" % int(cfg.dir_deg)
	var vc := sim.circ_speed_kms(cfg.dist_au, host)
	var hint: String
	if host != null:
		hint = "at %.1f×10⁻³ AU · circular %.1f km/s · escape %.1f km/s" % [cfg.dist_au * 1e3, vc, vc * sqrt(2.0)]
		# beyond ~0.6 Hill radii the sun's tide wins over the planet's pull
		var rh := MoonMath.hill_radius_au(maxf(host.r_au, 0.01), sim.mass_of(host), sim.mass_of(sim.sun))
		if cfg.dist_au > 0.6 * rh:
			hint += " · outside the stable zone — may escape"
	else:
		hint = "at %s AU · circular %.1f km/s · escape %.1f km/s" % [cfg.dist_au, vc, vc * sqrt(2.0)]
		if cfg.mass_e >= 20000.0:
			hint += " · will shine as a star"
	hint_label.text = hint
	Events.add_preview_changed.emit(cfg)
