class_name DockPanel
extends PanelContainer
## Bottom time dock: play/pause, speed presets, log speed slider, "Now",
## display toggles (orbits / labels / vectors) and the G slider.

const PRESETS := [
	["Real", 1.0], ["Day/s", 86400.0], ["Week/s", 604800.0],
	["Month/s", 2629800.0], ["Year/s", 31557600.0],
]

var sim: Simulation

var play_btn: Button
var preset_btns: Array = []      # [Button, speed]
var speed_slider: HSlider
var speed_label: Label
var orbits_btn: Button
var labels_btn: Button
var vectors_btn: Button
var g_slider: HSlider
var g_label: Label

var _last_speed := -1.0
var _last_playing := true


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.panel_style(16, 14))

	# desktop: everything on one row; touch: two centered rows so the dock
	# fits a phone screen without shrinking any control
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	add_child(outer)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	outer.add_child(row)
	var row2 := row
	if UITheme.touch:
		row2 = HBoxContainer.new()
		row2.add_theme_constant_override("separation", 12)
		row2.alignment = BoxContainer.ALIGNMENT_CENTER
		outer.add_child(row2)

	play_btn = Button.new()
	play_btn.tooltip_text = "Play / Pause (Space)"
	UITheme.style_chip(play_btn, 13)
	UITheme.set_chip_active(play_btn, true)
	play_btn.custom_minimum_size = Vector2(64, 48) if UITheme.touch else Vector2(52, 36)
	play_btn.pressed.connect(func() -> void: set_playing(not sim.playing))
	row.add_child(play_btn)

	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", 4)
	for p in PRESETS:
		var chip := Button.new()
		chip.text = p[0]
		UITheme.style_chip(chip, 11)
		var spd: float = p[1]
		chip.pressed.connect(func() -> void:
			sim.speed = spd
			_refresh_speed_ui())
		presets.add_child(chip)
		preset_btns.append([chip, spd])
	row.add_child(presets)

	var speed_col := VBoxContainer.new()
	speed_col.add_theme_constant_override("separation", 3)
	speed_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	speed_slider = HSlider.new()
	speed_slider.min_value = 0
	speed_slider.max_value = 1000
	speed_slider.step = 1
	UITheme.style_slider(speed_slider)
	speed_slider.custom_minimum_size = Vector2(190, 30) if UITheme.touch else Vector2(170, 16)
	speed_slider.value_changed.connect(func(v: float) -> void:
		sim.speed = Fmt.slider_to_speed(v)
		_refresh_speed_ui(false))
	speed_col.add_child(speed_slider)
	speed_label = UITheme.make_label("—", 10, UITheme.MUTED)
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_col.add_child(speed_label)
	if not UITheme.touch:
		row.add_child(speed_col)

	var now_btn := Button.new()
	now_btn.text = "Now"
	now_btn.tooltip_text = "Reset simulation to the current date"
	UITheme.style_chip(now_btn, 11)
	now_btn.pressed.connect(func() -> void: sim.reset_now())
	row.add_child(now_btn)

	if UITheme.touch:
		row2.add_child(speed_col)

	row2.add_child(_divider())

	orbits_btn = _toggle_btn("Orbits", "Toggle orbit paths (O)",
		func() -> void: Events.set_show_orbits(not Events.show_orbits))
	row2.add_child(orbits_btn)
	labels_btn = _toggle_btn("Labels", "Toggle labels (L)",
		func() -> void: Events.set_show_labels(not Events.show_labels))
	row2.add_child(labels_btn)
	vectors_btn = _toggle_btn("Vectors", "Toggle velocity vectors (V)",
		func() -> void: Events.set_show_vectors(not Events.show_vectors))
	row2.add_child(vectors_btn)

	row2.add_child(_divider())

	var g_col := VBoxContainer.new()
	g_col.add_theme_constant_override("separation", 3)
	g_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	g_col.tooltip_text = "Gravitational constant (switches to N-body gravity)"
	g_slider = HSlider.new()
	g_slider.min_value = 0
	g_slider.max_value = 1000
	g_slider.step = 1
	g_slider.value = 500
	UITheme.style_slider(g_slider)
	g_slider.custom_minimum_size = Vector2(120, 30) if UITheme.touch else Vector2(96, 16)
	g_slider.value_changed.connect(func(v: float) -> void:
		sim.set_g_scale(pow(10.0, (v - 500.0) / 500.0))   # 0.1× – 10×
		g_label.text = "G ×%.2f" % sim.g_scale)
	g_col.add_child(g_slider)
	g_label = UITheme.make_label("G ×1.00", 10, UITheme.MUTED)
	g_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g_col.add_child(g_label)
	row2.add_child(g_col)

	Events.orbits_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.labels_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.vectors_toggled.connect(func(_on: bool) -> void: _refresh_toggles())

	_refresh_toggles()
	_refresh_speed_ui()
	_refresh_play_icon()


func _divider() -> Control:
	var d := Panel.new()
	d.custom_minimum_size = Vector2(1, 26)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.1)
	d.add_theme_stylebox_override("panel", sb)
	return d


func _toggle_btn(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_chip(b, 11)
	b.pressed.connect(action)
	return b


func set_playing(on: bool) -> void:
	sim.playing = on
	_refresh_play_icon()


func _refresh_play_icon() -> void:
	play_btn.text = "Pause" if sim.playing else "Play"
	_last_playing = sim.playing


func _refresh_toggles() -> void:
	UITheme.set_chip_active(orbits_btn, Events.show_orbits)
	UITheme.set_chip_active(labels_btn, Events.show_labels)
	UITheme.set_chip_active(vectors_btn, Events.show_vectors)


func _refresh_speed_ui(move_slider := true) -> void:
	if move_slider:
		speed_slider.set_value_no_signal(Fmt.speed_to_slider(sim.speed))
	speed_label.text = Fmt.fmt_speed(sim.speed)
	for pb in preset_btns:
		var active: bool = absf(log(pb[1] / sim.speed)) < 0.02
		UITheme.set_chip_active(pb[0], active)
	_last_speed = sim.speed


func update_live() -> void:
	if sim.speed != _last_speed:
		_refresh_speed_ui()
	if sim.playing != _last_playing:
		_refresh_play_icon()
