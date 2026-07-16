class_name UITheme
## Shared palette + StyleBox/widget helpers approximating the prototype's
## glassmorphism (Godot has no backdrop blur, so panel alpha is raised a bit).

const TEXT := Color("e9eef7")
const MUTED := Color("8b97ab")
const ACCENT := Color("6cc4ff")
const ACCENT_WARM := Color("ffb454")
const PANEL_BG := Color(13 / 255.0, 18 / 255.0, 30 / 255.0, 0.8)
const PANEL_BORDER := Color(1, 1, 1, 0.08)

## set at boot by the UX autoload (before any panel is built): bumps fonts and
## hit targets for finger use on top of the window content scale
static var touch := false


## touch-aware font size: the desktop design uses dense 9–13 px labels which
## stay too small on a phone even after DPI scaling
static func fs(size: int) -> int:
	return size + 3 if touch else size


static func panel_style(radius := 16, margin := 16) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin * 0.8
	sb.content_margin_bottom = margin * 0.8
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 12
	return sb


static func flat_style(bg: Color, radius := 9) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	var mx := 15 if touch else 11
	var my := 10 if touch else 7
	sb.content_margin_left = mx
	sb.content_margin_right = mx
	sb.content_margin_top = my
	sb.content_margin_bottom = my
	return sb


## small pill button ("chip")
static func style_chip(btn: Button, font_size := 12) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", fs(font_size))
	btn.add_theme_stylebox_override("normal", flat_style(Color(0, 0, 0, 0)))
	btn.add_theme_stylebox_override("hover", flat_style(Color(1, 1, 1, 0.07)))
	btn.add_theme_stylebox_override("pressed", flat_style(Color(1, 1, 1, 0.1)))
	btn.add_theme_color_override("font_color", MUTED)
	btn.add_theme_color_override("font_hover_color", TEXT)
	btn.add_theme_color_override("font_pressed_color", TEXT)


static func set_chip_active(btn: Button, active: bool) -> void:
	if active:
		btn.add_theme_stylebox_override("normal", flat_style(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.14)))
		btn.add_theme_color_override("font_color", ACCENT)
	else:
		btn.add_theme_stylebox_override("normal", flat_style(Color(0, 0, 0, 0)))
		btn.add_theme_color_override("font_color", MUTED)


static func style_primary(btn: Button) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", fs(12))
	var sb := flat_style(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.16), 10)
	sb.border_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.35)
	sb.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal", sb)
	var hv := flat_style(Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.28), 10)
	btn.add_theme_stylebox_override("hover", hv)
	btn.add_theme_stylebox_override("pressed", hv)
	btn.add_theme_color_override("font_color", ACCENT)
	btn.add_theme_color_override("font_hover_color", ACCENT)


## red-tinted button for destructive actions (matches the info card's
## "Remove body" palette)
static func style_danger(btn: Button) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", fs(12))
	var red := Color(1, 96 / 255.0, 96 / 255.0)
	var sb := flat_style(Color(red.r, red.g, red.b, 0.12), 10)
	sb.border_color = Color(red.r, red.g, red.b, 0.3)
	sb.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal", sb)
	var hv := flat_style(Color(red.r, red.g, red.b, 0.22), 10)
	btn.add_theme_stylebox_override("hover", hv)
	btn.add_theme_stylebox_override("pressed", hv)
	btn.add_theme_color_override("font_color", Color("ff9d9d"))
	btn.add_theme_color_override("font_hover_color", Color("ffbdbd"))
	btn.add_theme_color_override("font_pressed_color", Color("ffbdbd"))


static func style_ghost(btn: Button) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", fs(12))
	var sb := flat_style(Color(1, 1, 1, 0.05), 10)
	sb.border_color = Color(1, 1, 1, 0.1)
	sb.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", flat_style(Color(1, 1, 1, 0.1), 10))
	btn.add_theme_color_override("font_color", MUTED)
	btn.add_theme_color_override("font_hover_color", TEXT)


## slim edge-drawer tab (chevron is drawn by EdgeDrawer itself)
static func style_drawer_handle(btn: Button) -> void:
	btn.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.set_content_margin_all(0)
	btn.add_theme_stylebox_override("normal", sb)
	var hv: StyleBoxFlat = sb.duplicate()
	hv.bg_color = Color(1, 1, 1, 0.12)
	btn.add_theme_stylebox_override("hover", hv)
	btn.add_theme_stylebox_override("pressed", hv)


static func make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fs(size))
	l.add_theme_color_override("font_color", color)
	return l


## small uppercase "eyebrow"/stat-key label
static func make_key_label(text: String) -> Label:
	var l := make_label(text.to_upper(), 10, MUTED)
	return l


static func style_slider(s: HSlider) -> void:
	s.focus_mode = Control.FOCUS_NONE
	s.custom_minimum_size = Vector2(140, 30) if touch else Vector2(120, 16)
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(1, 1, 1, 0.14)
	groove.set_corner_radius_all(2)
	groove.content_margin_top = 2
	groove.content_margin_bottom = 2
	s.add_theme_stylebox_override("slider", groove)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT
	fill.set_corner_radius_all(2)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
