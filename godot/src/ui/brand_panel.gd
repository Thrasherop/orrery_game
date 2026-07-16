class_name BrandPanel
extends PanelContainer
## Top-left brand/clock panel: eyebrow, simulated date + UTC clock, mode badge.

var date_label: Label
var clock_label: Label
var badge: Label


func _init() -> void:
	add_theme_stylebox_override("panel", UITheme.panel_style())
	custom_minimum_size = Vector2(230, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	add_child(box)

	var eyebrow := HBoxContainer.new()
	eyebrow.add_theme_constant_override("separation", 8)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(6, 6)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = UITheme.ACCENT_WARM
	dsb.set_corner_radius_all(3)
	dot.add_theme_stylebox_override("panel", dsb)
	eyebrow.add_child(dot)
	eyebrow.add_child(UITheme.make_key_label("Orrery · Solar System"))
	box.add_child(eyebrow)

	date_label = UITheme.make_label("—", 21, UITheme.TEXT)
	box.add_child(date_label)
	clock_label = UITheme.make_label("—", 12, UITheme.MUTED)
	box.add_child(clock_label)
	badge = UITheme.make_key_label("Kepler ephemeris")
	badge.add_theme_font_size_override("font_size", 9)
	box.add_child(badge)


func update_clock(ms: float) -> void:
	var dc := Fmt.fmt_date(ms)
	date_label.text = dc[0]
	clock_label.text = dc[1]


func set_mode(text: String, gravity: bool) -> void:
	badge.text = text.to_upper()
	badge.add_theme_color_override("font_color", UITheme.ACCENT_WARM if gravity else UITheme.MUTED)
