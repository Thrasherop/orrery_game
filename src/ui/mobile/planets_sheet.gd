class_name PlanetsSheet
extends MobileSheet
## Mobile replacement for the left planet rail: a modal bottom sheet listing
## every body as a full-width row. A planet with moons gets a chevron button
## that expands its moons inline (tap — no long-press). Tapping a row selects
## the body and closes the sheet.

signal add_clicked
signal add_moon_clicked(planet)

var sim: Simulation
var _expanded: SimBody = null


func _init() -> void:
	super(true, 0.0)
	max_ratio = 0.78


func setup(sim_: Simulation) -> void:
	sim = sim_
	Events.bodies_changed.connect(func() -> void:
		if is_open():
			rebuild())


func open_sheet() -> void:
	rebuild()
	open()


func rebuild() -> void:
	for c in content.get_children():
		content.remove_child(c)
		c.queue_free()
	add_title("Bodies")

	# group simulated moons by their CURRENT host (a stolen moon appears
	# under its captor)
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
		var body: SimBody = b

		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		content.add_child(line)
		var btn := _body_row(b.body_name, b.color)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(func() -> void:
			Events.select_requested.emit(body)
			close())
		line.add_child(btn)
		if expandable:
			var chev := Button.new()
			chev.text = "▾" if _expanded == b else "▸"
			chev.tooltip_text = "Show moons"
			UITheme.style_chip(chev, 13)
			chev.custom_minimum_size = Vector2(52, 52)
			chev.pressed.connect(func() -> void:
				_expanded = null if _expanded == body else body
				rebuild())
			line.add_child(chev)

		if expandable and _expanded == b:
			for mb in hosted:
				var moon: SimBody = mb
				var mbtn := _body_row(moon.body_name, moon.color, 26)
				mbtn.pressed.connect(func() -> void:
					Events.select_requested.emit(moon)
					close())
				content.add_child(mbtn)
			for mname in deco:
				var md := _moon_dict(b, mname)
				var dbtn := _body_row(mname, Color(md.color) * Color(1, 1, 1, 0.45), 26)
				dbtn.disabled = true
				content.add_child(dbtn)
			if not sim.moons_simulated:
				content.add_child(_hint_row("Enable “Simulate moons” in Settings"))
			elif deco.size() > 0:
				content.add_child(_hint_row("Fast moons disabled in Settings"))
			# user-added moons are always simulated — independent of the
			# catalog-moon flags above
			var addm := _accent_row("⊕  Add moon of %s…" % b.body_name, 26)
			addm.pressed.connect(func() -> void:
				close()
				add_moon_clicked.emit(body))
			content.add_child(addm)

	var add_btn := _accent_row("⊕  Add body…")
	add_btn.pressed.connect(func() -> void:
		close()
		add_clicked.emit())
	content.add_child(add_btn)


func _moon_dict(planet: SimBody, mname: String) -> Dictionary:
	for md in planet.moons:
		if md.name == mname:
			return md
	return { color = "#888888" }


func _hint_row(text: String) -> Control:
	var lbl := UITheme.make_label(text, 10, UITheme.MUTED)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var row := HBoxContainer.new()
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(40, 0)
	row.add_child(pad)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	return row


func _accent_row(text: String, indent := 0) -> Button:
	var btn := Button.new()
	btn.text = text
	UITheme.style_row(btn)
	btn.add_theme_color_override("font_color", UITheme.ACCENT)
	btn.add_theme_color_override("font_hover_color", UITheme.ACCENT)
	btn.add_theme_color_override("font_pressed_color", UITheme.ACCENT)
	if indent > 0:
		var sb: StyleBoxFlat = btn.get_theme_stylebox("normal").duplicate()
		sb.content_margin_left += indent
		btn.add_theme_stylebox_override("normal", sb)
	return btn


## list row: colored dot + name (dot drawn via an overlay HBox like the rail)
func _body_row(text: String, dot_color: Color, indent := 0) -> Button:
	var btn := Button.new()
	UITheme.style_row(btn)
	if indent > 0:
		btn.custom_minimum_size.y = 46
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 14 + indent
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(10, 10) if indent == 0 else Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = dot_color
	dsb.set_corner_radius_all(5)
	dot.add_theme_stylebox_override("panel", dsb)
	row.add_child(dot)
	var lbl := UITheme.make_label(text, 13 if indent == 0 else 12,
		UITheme.TEXT if indent == 0 else UITheme.MUTED)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)
	btn.add_child(row)
	return btn
