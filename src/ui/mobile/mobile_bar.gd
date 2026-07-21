class_name MobileBar
extends PanelContainer
## Persistent bottom action bar (mobile): the only always-on chrome besides the
## status pill. Five thumb-sized controls — menu, planet list, play/pause,
## current time speed (opens the time sheet) and add-body. Everything else
## lives in bottom sheets.

signal menu_pressed
signal planets_pressed
signal speed_pressed
signal add_pressed

var sim: Simulation
var play_btn: Button
var speed_btn: Button

var _last_playing := true
var _last_speed := -1.0


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.bar_style())
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	row.add_child(_chip("⋯", "Menu: saves, settings, display", func() -> void:
		menu_pressed.emit()))
	row.add_child(_chip("Planets", "All bodies — tap one to follow it", func() -> void:
		planets_pressed.emit()))

	play_btn = Button.new()
	play_btn.tooltip_text = "Play / Pause"
	UITheme.style_primary(play_btn)
	play_btn.add_theme_font_size_override("font_size", UITheme.fs(13))
	play_btn.custom_minimum_size = Vector2(84, 48)
	play_btn.pressed.connect(func() -> void:
		sim.playing = not sim.playing
		update_live())
	row.add_child(play_btn)

	speed_btn = Button.new()
	speed_btn.tooltip_text = "Time speed — tap to change"
	UITheme.style_ghost(speed_btn)
	speed_btn.custom_minimum_size = Vector2(92, 48)
	speed_btn.pressed.connect(func() -> void: speed_pressed.emit())
	row.add_child(speed_btn)

	row.add_child(_chip("⊕", "Add a body (or a moon of the selected planet)", func() -> void:
		add_pressed.emit()))

	update_live()


func _chip(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	UITheme.style_ghost(b)
	b.add_theme_font_size_override("font_size", UITheme.fs(13))
	b.custom_minimum_size = Vector2(56, 48)
	b.pressed.connect(action)
	return b


func update_live() -> void:
	if sim.playing != _last_playing or _last_speed < 0.0:
		play_btn.text = "Pause" if sim.playing else "Play"
		_last_playing = sim.playing
	if sim.speed != _last_speed:
		speed_btn.text = _compact_speed(sim.speed)
		_last_speed = sim.speed


## short speed readout that fits a bar chip ("1.0 d/s", "3.2 yr/s")
static func _compact_speed(s: float) -> String:
	if s < 60.0:
		return "%.0f sec/s" % s
	if s < 3600.0:
		return "%.0f min/s" % (s / 60.0)
	if s < 86400.0:
		return "%.1f hr/s" % (s / 3600.0)
	if s < 31557600.0:
		return "%.1f d/s" % (s / 86400.0)
	return "%.1f yr/s" % (s / 31557600.0)
