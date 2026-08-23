class_name TimeSheet
extends MobileSheet
## Mobile time controls: speed presets and the log speed slider. Play/pause
## lives in the action bar, and "Real scale" — a display setting, not a time
## one — sits with the other display toggles in Settings and the menu.

var sim: Simulation

var preset_btns: Array = []      # [Button, speed]
var speed_slider: HSlider
var speed_label: Label

var _last_speed := -1.0


func _init() -> void:
	super(true, 0.0)


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_title("Time speed")

	var presets := HFlowContainer.new()
	presets.add_theme_constant_override("h_separation", 8)
	presets.add_theme_constant_override("v_separation", 8)
	content.add_child(presets)
	for p in DockPanel.PRESETS:
		var chip := Button.new()
		chip.text = p[0]
		UITheme.style_chip(chip, 12)
		chip.custom_minimum_size = Vector2(0, 44)
		var spd: float = p[1]
		chip.pressed.connect(func() -> void:
			sim.speed = spd
			_refresh_speed_ui())
		presets.add_child(chip)
		preset_btns.append([chip, spd])

	speed_slider = HSlider.new()
	speed_slider.min_value = 0
	speed_slider.max_value = 1000
	speed_slider.step = 1
	UITheme.style_slider(speed_slider)
	speed_slider.custom_minimum_size = Vector2(0, 34)
	speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_slider.value_changed.connect(func(v: float) -> void:
		sim.speed = Fmt.slider_to_speed(v)
		_refresh_speed_ui(false))
	content.add_child(speed_slider)
	speed_label = UITheme.make_label("—", 11, UITheme.MUTED)
	speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(speed_label)

	_refresh_speed_ui()


func _refresh_speed_ui(move_slider := true) -> void:
	if move_slider:
		speed_slider.set_value_no_signal(Fmt.speed_to_slider(sim.speed))
	speed_label.text = Fmt.fmt_speed(sim.speed)
	for pb in preset_btns:
		var active: bool = absf(log(pb[1] / sim.speed)) < 0.02
		UITheme.set_chip_active(pb[0], active)
	_last_speed = sim.speed


func update_live() -> void:
	if not is_open():
		return
	if sim.speed != _last_speed:
		_refresh_speed_ui()
