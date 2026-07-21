class_name RailPanel
extends PanelContainer
## Left planet rail: one button per body (colored dot + name) plus "Add body…".
## Long-pressing (or right-clicking) a planet expands a dropdown of its moons —
## grouped by CURRENT host, so a stolen moon appears under its captor — with an
## "Add moon…" row when moons are simulated.

signal add_clicked
signal add_moon_clicked(planet)

const LONG_PRESS_S := 0.45

var sim: Simulation
var _scroll: ScrollContainer
var _box: VBoxContainer
var _buttons := {}   # SimBody -> Button
var _expanded: SimBody = null

var _lp_timer: Timer
var _lp_body: SimBody = null
var _lp_fired := false


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.panel_style(16, 8))
	# the list scrolls once it would overflow the window (small screens, or
	# many added bodies)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 2)
	_scroll.add_child(_box)
	_lp_timer = Timer.new()
	_lp_timer.one_shot = true
	_lp_timer.wait_time = LONG_PRESS_S
	_lp_timer.timeout.connect(_on_long_press)
	add_child(_lp_timer)
	rebuild()
	Events.bodies_changed.connect(rebuild)
	Events.selection_changed.connect(_on_selection_changed)


func _ready() -> void:
	get_viewport().size_changed.connect(_update_size_cap)
	_update_size_cap()


## size the scroll area to the list, capped to a fraction of the window height
func _update_size_cap() -> void:
	if not is_inside_tree():
		return
	var need := _box.get_combined_minimum_size()
	var vp_h := get_viewport_rect().size.y
	# touch: the rail is vertically centered — keep it clear of the brand
	# panel (top, now taller with the Saves/Reset row) and the two-row dock
	# (bottom); the list scrolls inside whatever strip remains
	var max_h := maxf(vp_h - 420.0, 100.0) if UITheme.touch else vp_h * 0.68
	_scroll.custom_minimum_size = Vector2(need.x + 6, minf(need.y, max_h))


func rebuild() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	_buttons.clear()

	# group simulated moons by their CURRENT host
	var by_host := {}
	for mb in sim.moons:
		if mb.host != null:
			if not by_host.has(mb.host):
				by_host[mb.host] = []
			by_host[mb.host].append(mb)
	if _expanded != null and not is_instance_valid(_expanded):
		_expanded = null

	for b in sim.all_bodies():
		if b.is_moon and b.host != null:
			continue   # listed under its host's dropdown
		var deco := sim.decorative_moon_names(b) if not (b.is_sun or b.custom or b.is_moon) else []
		var hosted: Array = by_host.get(b, [])
		var expandable: bool = hosted.size() > 0 or deco.size() > 0
		var text: String = b.body_name
		if expandable:
			text += "  ▾" if _expanded == b else "  ▸"
		var btn := _make_item(text, b.color)
		var body: SimBody = b
		btn.pressed.connect(func() -> void:
			if _lp_fired:
				_lp_fired = false   # the long-press already expanded — don't select
				return
			Events.select_requested.emit(body))
		if expandable:
			btn.button_down.connect(func() -> void:
				_lp_fired = false
				_lp_body = body
				_lp_timer.start())
			btn.button_up.connect(func() -> void: _lp_timer.stop())
			btn.gui_input.connect(func(ev: InputEvent) -> void:
				var mb_ev := ev as InputEventMouseButton
				if mb_ev != null and mb_ev.pressed and mb_ev.button_index == MOUSE_BUTTON_RIGHT:
					_toggle_expanded(body))
			btn.tooltip_text = "Hold (or right-click) to show moons"
		_box.add_child(btn)
		_buttons[b] = btn

		if expandable and _expanded == b:
			for mb in hosted:
				var moon: SimBody = mb
				var mbtn := _make_item(moon.body_name, moon.color, 24)
				mbtn.pressed.connect(func() -> void: Events.select_requested.emit(moon))
				_box.add_child(mbtn)
				_buttons[moon] = mbtn
			for mname in deco:
				var md := _moon_dict(b, mname)
				var dbtn := _make_item(mname, Color(md.color) * Color(1, 1, 1, 0.45), 24)
				dbtn.disabled = true
				_box.add_child(dbtn)
			if not sim.moons_simulated:
				_box.add_child(_hint_row("Enable “Simulate moons” in Settings"))
			elif deco.size() > 0:
				_box.add_child(_hint_row("Fast moons disabled in Settings"))
			# user-added moons are always simulated — independent of the
			# catalog-moon flags above
			var addm := _make_item("Add moon…", UITheme.ACCENT, 24)
			var add_lbl_m: Label = addm.get_meta("name_label")
			add_lbl_m.add_theme_color_override("font_color", UITheme.ACCENT)
			addm.pressed.connect(func() -> void: add_moon_clicked.emit(body))
			_box.add_child(addm)

	var add_btn := _make_item("Add body…", UITheme.ACCENT)
	var add_lbl: Label = add_btn.get_meta("name_label")
	add_lbl.add_theme_color_override("font_color", UITheme.ACCENT)
	add_btn.pressed.connect(func() -> void: add_clicked.emit())
	_box.add_child(add_btn)
	_on_selection_changed(Events.selected)
	if is_inside_tree():
		_update_size_cap()


func _on_long_press() -> void:
	_lp_fired = true
	_toggle_expanded(_lp_body)


func _toggle_expanded(b: SimBody) -> void:
	_expanded = null if _expanded == b else b
	rebuild()


func _moon_dict(planet: SimBody, mname: String) -> Dictionary:
	for md in planet.moons:
		if md.name == mname:
			return md
	return { color = "#888888" }


func _hint_row(text: String) -> Control:
	var lbl := UITheme.make_label(text, 9, UITheme.MUTED)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var row := HBoxContainer.new()
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(33, 0)
	row.add_child(pad)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	return row


func _make_item(text: String, dot_color: Color, indent := 0) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(172, 42) if UITheme.touch else Vector2(150, 30)
	if indent > 0 and UITheme.touch:
		btn.custom_minimum_size.y = 38   # sub-rows a touch tighter
	btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(0, 0, 0, 0)))
	btn.add_theme_stylebox_override("hover", UITheme.flat_style(Color(1, 1, 1, 0.06)))
	btn.add_theme_stylebox_override("pressed", UITheme.flat_style(Color(1, 1, 1, 0.08)))

	# content row overlaid on the button (colored dot + name)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 9 + indent
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(8, 8) if indent == 0 else Vector2(6, 6)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = dot_color
	dsb.set_corner_radius_all(4)
	dot.add_theme_stylebox_override("panel", dsb)
	row.add_child(dot)
	var lbl := UITheme.make_label(text, 12 if indent == 0 else 11, UITheme.MUTED)
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
