extends Node
## Platform/UX adaptation (autoload "UX"). Decides whether we're on a handheld
## touch device and applies a DPI-derived UI scale via the window's
## content_scale_factor — every Control keeps its layout code, it just renders
## bigger. Desktop and desktop web keep scale 1.0 and are pixel-identical.
##
## `set_simulated_handheld(true)` can be called from a test harness *before*
## the HUD is built to preview the phone experience on desktop.

## UI icon glyphs (⚙ ✕ ⊕ ↺ ▾ ▸ ← ⋯, super/subscripts) — a DejaVu Sans subset.
## Godot's built-in font lacks them and normally borrows them from OS system
## fonts, which don't exist on web: without this fallback the icons render as
## tofu boxes there.
const SYMBOL_FONT: FontFile = preload("res://assets/fonts/ui_symbols.ttf")

var handheld := false
var scale := 1.0
var scale_override := 0.0   # test harnesses: force a scale (>0) despite desktop DPI


func _ready() -> void:
	_install_symbol_fallback()
	handheld = OS.has_feature("android") or OS.has_feature("ios") \
		or OS.has_feature("web_android") or OS.has_feature("web_ios")
	UITheme.touch = handheld
	apply_scale()
	get_window().size_changed.connect(apply_scale)


## append the symbol font to the default theme font's fallback chain — every
## Control resolves missing glyphs through it, on all platforms identically
func _install_symbol_fallback() -> void:
	var base := ThemeDB.fallback_font
	if base != null and not base.fallbacks.has(SYMBOL_FONT):
		base.fallbacks = base.fallbacks + [SYMBOL_FONT]


func set_simulated_handheld(on: bool) -> void:
	handheld = on
	UITheme.touch = on
	apply_scale()


func apply_scale() -> void:
	scale = _compute_scale()
	get_window().content_scale_factor = scale


func _compute_scale() -> float:
	if scale_override > 0.0:
		return scale_override
	if not handheld:
		return 1.0
	var win := get_window().size
	# fit: aim for ~540 logical px on the short side so the HUD panels always
	# have room; dpi: don't magnify past true physical sizing (keeps tablets
	# from getting a blown-up phone UI). Use whichever is smaller.
	var fit := float(mini(win.x, win.y)) / 540.0
	var dpi := DisplayServer.screen_get_dpi()
	var s := fit if dpi <= 96 else minf(dpi / 160.0, fit)
	return clampf(s, 1.0, 3.0)
