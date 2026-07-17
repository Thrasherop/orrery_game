class_name DockPanel
extends PanelContainer
## Bottom time dock: play/pause, speed presets, log speed slider and "Now".
## (Display toggles and the G slider live in the Settings panel.)

const PRESETS := [
	["Real", 1.0], ["Day/s", 86400.0], ["Week/s", 604800.0],
	["Month/s", 2629800.0], ["Year/s", 31557600.0],
]

var sim: Simulation

var play_btn: Button
var preset_btns: Array = []      # [Button, speed]
var speed_slider: HSlider
var speed_label: Label

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

	_refresh_speed_ui()
	_refresh_play_icon()


func set_playing(on: bool) -> void:
	sim.playing = on
	_refresh_play_icon()


func _refresh_play_icon() -> void:
	play_btn.text = "Pause" if sim.playing else "Play"
	_last_playing = sim.playing


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
