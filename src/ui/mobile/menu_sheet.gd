class_name MenuSheet
extends MobileSheet
## Mobile overflow menu: saves / reset / settings as tap rows, quick display
## toggles (orbits, labels, vectors), and the physics-load readout embedded at
## the bottom (the desktop perf drawer's content).

signal saves_clicked
signal reset_clicked
signal settings_clicked

var sim: Simulation

var _orbits_btn: Button
var _labels_btn: Button
var _vectors_btn: Button
var _real_btn: Button


func _init() -> void:
	super(true, 0.0)
	max_ratio = 0.78


func setup(sim_: Simulation) -> void:
	sim = sim_

	content.add_child(_row("Saves…", "Save / load experiments", func() -> void:
		close()
		saves_clicked.emit()))
	content.add_child(_row("Reset", "Restore the pristine solar system", func() -> void:
		close()
		reset_clicked.emit()))
	content.add_child(_row("Settings", "Moon simulation, path frames, gravity", func() -> void:
		close()
		settings_clicked.emit()))

	content.add_child(UITheme.make_key_label("Display"))
	var toggles := HBoxContainer.new()
	toggles.add_theme_constant_override("separation", 8)
	content.add_child(toggles)
	_orbits_btn = _toggle_chip(toggles, "Orbits", func() -> void:
		Events.set_show_orbits(not Events.show_orbits))
	_labels_btn = _toggle_chip(toggles, "Labels", func() -> void:
		Events.set_show_labels(not Events.show_labels))
	_vectors_btn = _toggle_chip(toggles, "Vectors", func() -> void:
		Events.set_show_vectors(not Events.show_vectors))
	_real_btn = _toggle_chip(toggles, "Real scale", func() -> void:
		Events.set_real_scale(not Units.real_scale))
	_real_btn.tooltip_text = "Show true distances and sizes — planets shrink to dots and only the orbits remain visible"

	# physics-load readout (refreshes itself via _process)
	var perf := PerfPanel.new()
	perf.setup(sim)
	perf.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	content.add_child(perf)

	Events.orbits_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.labels_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.vectors_toggled.connect(func(_on: bool) -> void: _refresh_toggles())
	Events.real_scale_changed.connect(func(_on: bool) -> void: _refresh_toggles())
	_refresh_toggles()


func open_sheet() -> void:
	_refresh_toggles()
	open()


func _row(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_row(b)
	b.pressed.connect(action)
	return b


func _toggle_chip(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	UITheme.style_chip(b, 12)
	b.custom_minimum_size = Vector2(0, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _refresh_toggles() -> void:
	UITheme.set_chip_active(_orbits_btn, Events.show_orbits)
	UITheme.set_chip_active(_labels_btn, Events.show_labels)
	UITheme.set_chip_active(_vectors_btn, Events.show_vectors)
	UITheme.set_chip_active(_real_btn, Units.real_scale)
