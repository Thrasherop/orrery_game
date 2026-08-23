class_name SettingsPanel
extends CanvasLayer
## Modal settings overlay: moon simulation flags (locked once physics starts),
## the display toggles and the G slider (moved here from the time dock — speed
## stays in the dock). Code-built like every other panel.

# Indexed by TrailFrames enum (MODE_LOCAL, MODE_INERTIAL, MODE_GALAXY,
# MODE_FOCUS, MODE_TRUE) — NOT display order. See TrailFrames.MODE_NAMES.
const MODE_TIPS := [
	# MODE_LOCAL — "Sun-locked"
	"Reference frame: the Sun, held still — the classic orrery view. Planets trace clean orbit rings (moons ring their planet). If a ring still wiggles, that's the Sun being physically tugged by something heavy, not the planet swerving.",
	# MODE_INERTIAL — "Barycentric" (advanced)
	"Advanced. Reference frame: the system's center of mass, held still. Orbits keep their crisp shape, but the Sun's own wobble is baked into every path — so a heavy newcomer makes distant trails zig-zag into nonsense. Use \"True motion\" for the honest version.",
	# MODE_GALAXY — "True Barycentric" (advanced)
	"Advanced. The Barycentric view plus the Solar System's drift through the Milky Way, stretching orbits into long helices. Built the same sun-anchored way, so heavy newcomers still smear distant paths into zig-zags.",
	# MODE_FOCUS — "Focus"
	"Reference frame: the body you've selected, held still. The other planets trace looping retrograde curls around it — the way ancient astronomers watched the planets wander from Earth.",
	# MODE_TRUE — "True motion"
	"Reference frame: the system's center of mass, with every body drawn at its exact position (plus a gentle galactic drift). The honest \"how it really moves\" view — the Sun wobbles as its own body and no swerve is stamped onto anything else. Tight clusters far from the center get a fisheye stretch; that's inherent, not a bug.",
]

var sim: Simulation
var _embedded := false   # content lives in a MobileSheet; no own overlay/modal

var _moons_check: CheckButton
var _fast_check: CheckButton
var _default_check: CheckButton
var _lock_note: Label
var _orbits_btn: Button
var _labels_btn: Button
var _vectors_btn: Button
var _real_btn: Button        # embedded (mobile) only — desktop's lives in the dock
var _mode_btns := {}         # TrailFrames mode int -> Button (primary + advanced)
var _adv_toggle: Button      # "Advanced" disclosure for the barycentric frames
var _adv_row: HBoxContainer  # holds the advanced-frame chips (hidden by default)
var _mode_desc: Label
var _moon_frame_check: CheckButton
var _g_slider: HSlider
var _g_label: Label
var _last_g := 1.0


## with embed_box (mobile) the content is built into that container — a
## MobileSheet owns visibility/dismissal and this node is only the controller
func setup(sim_: Simulation, embed_box: Control = null) -> void:
	sim = sim_
	_embedded = embed_box != null
	var box: VBoxContainer

	if _embedded:
		box = VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		embed_box.add_child(box)
	else:
		layer = 4
		visible = false

		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.5)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		dim.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed:
				close_panel())
		add_child(dim)

		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(center)

		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UITheme.panel_style())
		center.add_child(panel)

		box = VBoxContainer.new()
		box.add_theme_constant_override("separation", 8)
		box.custom_minimum_size = Vector2(380 if UITheme.touch else 360, 0)
		panel.add_child(box)

		var header := HBoxContainer.new()
		box.add_child(header)
		var title := UITheme.make_label("Settings", 15, UITheme.TEXT)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		var close := Button.new()
		close.text = "✕"
		UITheme.style_ghost(close)
		close.pressed.connect(close_panel)
		header.add_child(close)

	# --- Moons ------------------------------------------------------------
	box.add_child(UITheme.make_key_label("Moons"))
	_moons_check = _check("Simulate moons",
		"Moons become real bodies with their own gravity — they can wander, be stolen, or crash",
		func(on: bool) -> void:
			sim.set_moons_simulated(on)   # rejected silently once physics started
			if sim.moons_simulated != on:
				Events.toast_requested.emit("Locked once N-body physics has started")
			_refresh())
	box.add_child(_moons_check)
	_fast_check = _check("Include fast inner moons (%s)" % ", ".join(Catalog.EXPENSIVE_MOONS),
		"These need very small physics steps — disable them if time speed lags",
		func(on: bool) -> void:
			sim.set_expensive_moons(on)
			if sim.sim_expensive_moons != on:
				Events.toast_requested.emit("Locked once N-body physics has started")
			_refresh())
	box.add_child(_indent(_fast_check))
	_lock_note = UITheme.make_label("Locked once N-body physics has started — use Reset or a new save to change.", 10, UITheme.MUTED)
	_lock_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_lock_note)
	_default_check = _check("Enable moons by default in new saves", "",
		func(on: bool) -> void: Prefs.set_moons_default(on))
	box.add_child(_default_check)

	# --- Display ----------------------------------------------------------
	box.add_child(_spacer())
	box.add_child(UITheme.make_key_label("Display"))
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 6)
	box.add_child(toggles)
	_orbits_btn = _toggle_btn("Orbits", "Toggle orbit paths (O)",
		func() -> void: Events.set_show_orbits(not Events.show_orbits))
	toggles.add_child(_orbits_btn)
	_labels_btn = _toggle_btn("Labels", "Toggle labels (L)",
		func() -> void: Events.set_show_labels(not Events.show_labels))
	toggles.add_child(_labels_btn)
	_vectors_btn = _toggle_btn("Vectors", "Toggle velocity vectors (V)",
		func() -> void: Events.set_show_vectors(not Events.show_vectors))
	toggles.add_child(_vectors_btn)
	# desktop keeps this in the time dock, which is always on screen there;
	# mobile has no dock, so the view scale belongs with the display toggles
	if _embedded:
		_real_btn = _toggle_btn("Real scale",
			"Show true distances and sizes — planets shrink to dots and only the orbits remain visible",
			func() -> void: Events.set_real_scale(not Units.real_scale))
		toggles.add_child(_real_btn)

	# --- Path frame ---------------------------------------------------------
	box.add_child(_spacer())
	box.add_child(UITheme.make_key_label("Path frame"))
	# primary frames — the intuitive everyday views
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 6)
	box.add_child(modes)
	for m in TrailFrames.MODE_PRIMARY:
		modes.add_child(_make_mode_chip(m))
	# advanced frames — barycentric constructions that read as nonsense unless
	# you know what they are; tucked behind a disclosure toggle
	_adv_toggle = _toggle_btn("Advanced ⋯",
		"Barycentric-construction frames — technical views the everyday modes replace",
		func() -> void: _set_advanced(not _adv_row.visible))
	box.add_child(_adv_toggle)
	_adv_row = HBoxContainer.new()
	_adv_row.add_theme_constant_override("separation", 6)
	_adv_row.visible = false
	box.add_child(_adv_row)
	for m in TrailFrames.MODE_ADVANCED:
		_adv_row.add_child(_make_mode_chip(m))
	_mode_desc = UITheme.make_label("", 10, UITheme.MUTED)
	_mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_mode_desc)
	_moon_frame_check = _check("Moon paths follow the frame",
		"Off: moon paths ring their host planet. On: moons are drawn in the selected path frame like every other body — in Sun-locked you see a moon's true wavy path around the Sun.",
		func(on: bool) -> void: Events.set_moon_trail_frame(on))
	box.add_child(_moon_frame_check)

	# --- Physics ----------------------------------------------------------
	box.add_child(_spacer())
	box.add_child(UITheme.make_key_label("Physics"))
	var g_col := VBoxContainer.new()
	g_col.add_theme_constant_override("separation", 3)
	g_col.tooltip_text = "Gravitational constant (switches to N-body gravity)"
	box.add_child(g_col)
	_g_slider = HSlider.new()
	_g_slider.min_value = 0
	_g_slider.max_value = 1000
	_g_slider.step = 1
	_g_slider.value = 500
	UITheme.style_slider(_g_slider)
	_g_slider.custom_minimum_size = Vector2(0, 30 if UITheme.touch else 16)
	_g_slider.value_changed.connect(func(v: float) -> void:
		sim.set_g_scale(pow(10.0, (v - 500.0) / 500.0))   # 0.1× – 10×
		_g_label.text = "G ×%.2f" % sim.g_scale
		_refresh())
	g_col.add_child(_g_slider)
	_g_label = UITheme.make_label("G ×1.00", 10, UITheme.MUTED)
	_g_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_g_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g_col.add_child(_g_label)

	Events.orbits_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.labels_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.vectors_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.real_scale_changed.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.trail_mode_changed.connect(func(_m: int) -> void: _refresh_toggles())
	Events.mode_changed.connect(_refresh)
	_refresh()


func _check(text: String, tip: String, on_toggled: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.tooltip_text = tip
	c.focus_mode = Control.FOCUS_NONE
	c.add_theme_font_size_override("font_size", UITheme.fs(12))
	c.add_theme_color_override("font_color", UITheme.TEXT)
	c.add_theme_color_override("font_disabled_color", UITheme.MUTED)
	c.toggled.connect(on_toggled)
	return c


func _indent(inner: Control) -> Control:
	var row := HBoxContainer.new()
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(24, 0)
	row.add_child(pad)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(inner)
	return row


func _spacer() -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, 4)
	return s


func _toggle_btn(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_chip(b, 11)
	b.pressed.connect(action)
	return b


## a path-frame chip wired to select that TrailFrames mode, registered in
## _mode_btns by mode int (display order is decoupled from the enum)
func _make_mode_chip(m: int) -> Button:
	var btn := _toggle_btn(TrailFrames.MODE_NAMES[m], MODE_TIPS[m],
		func() -> void: Events.set_trail_mode(m))
	_mode_btns[m] = btn
	return btn


func _set_advanced(open: bool) -> void:
	_adv_row.visible = open
	UITheme.set_chip_active(_adv_toggle, open)


func open_panel() -> void:
	_refresh()
	if not _embedded:
		visible = true


func close_panel() -> void:
	if not _embedded:
		visible = false


func is_open() -> bool:
	return visible and not _embedded


func _refresh() -> void:
	# NOTE: the toggles are never `disabled` — Godot's disabled CheckButton
	# renders indistinguishably from unchecked, which would misreport the
	# state. The sim setters reject changes once physics started; the note
	# and a toast on attempt explain the lock.
	var locked := sim.physics_active or sim.physics_permanent
	_moons_check.set_pressed_no_signal(sim.moons_simulated)
	_fast_check.set_pressed_no_signal(sim.sim_expensive_moons)
	_lock_note.visible = locked
	_default_check.set_pressed_no_signal(Prefs.moons_default())
	_g_slider.set_value_no_signal(500.0 + 500.0 * log(sim.g_scale) / log(10.0))
	_g_label.text = "G ×%.2f" % sim.g_scale
	_last_g = sim.g_scale
	_refresh_toggles()


func _refresh_toggles() -> void:
	UITheme.set_chip_active(_orbits_btn, Events.show_orbits)
	UITheme.set_chip_active(_labels_btn, Events.show_labels)
	UITheme.set_chip_active(_vectors_btn, Events.show_vectors)
	if _real_btn != null:
		UITheme.set_chip_active(_real_btn, Units.real_scale)
	for m in _mode_btns:
		UITheme.set_chip_active(_mode_btns[m], TrailFrames.mode == m)
	_moon_frame_check.set_pressed_no_signal(TrailFrames.moon_frame)
	# keep the active frame visible: auto-open the Advanced row when an advanced
	# frame is selected (e.g. restored from a save or set via the P key)
	if TrailFrames.mode in TrailFrames.MODE_ADVANCED and not _adv_row.visible:
		_set_advanced(true)
	_mode_desc.text = MODE_TIPS[TrailFrames.mode]


## external G change while the panel is open (loading a save, reset)
func update_live() -> void:
	if (_embedded or visible) and sim.g_scale != _last_g:
		_refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	if _embedded or not visible:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_panel()
