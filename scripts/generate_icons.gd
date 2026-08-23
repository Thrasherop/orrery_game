extends SceneTree
## Rasterises the icon SVGs into the PNGs the Web and Android export presets
## need. Run via scripts/generate-icons.ps1 (or:
## `godot --headless --path . -s scripts/generate_icons.gd`).
##
## Sources are 512x512 viewBoxes, so scale = size / 512. Godot rasterises them
## with the same ThorVG backend it uses for res://icon.svg, so what ships in the
## PNGs matches what the editor shows.

const SRC_SIZE := 512.0
const OUT_DIR := "res://assets/icons"

## [source svg, output png basename, pixel size]
const TARGETS: Array = [
	# Web / PWA + the Android legacy launcher icon (192).
	["res://icon.svg", "icon_512.png", 512],
	["res://icon.svg", "icon_192.png", 192],
	["res://icon.svg", "icon_180.png", 180],
	["res://icon.svg", "icon_144.png", 144],
	["res://icon.svg", "icon_48.png", 48],
	["res://icon.svg", "icon_32.png", 32],
	["res://icon.svg", "icon_16.png", 16],
	# Android adaptive icon layers (108dp canvas at xxxhdpi).
	["res://assets/icons/icon_foreground.svg", "adaptive_foreground_432.png", 432],
	["res://assets/icons/icon_background.svg", "adaptive_background_432.png", 432],
	["res://assets/icons/icon_monochrome.svg", "adaptive_monochrome_432.png", 432],
]


func _init() -> void:
	var failed := 0
	for t: Array in TARGETS:
		if not _render(t[0], "%s/%s" % [OUT_DIR, t[1]], t[2]):
			failed += 1
	quit(1 if failed > 0 else 0)


func _render(svg_path: String, out_path: String, size: int) -> bool:
	var svg := FileAccess.get_file_as_bytes(svg_path)
	if svg.is_empty():
		printerr("cannot read ", svg_path)
		return false

	var img := Image.new()
	var err := img.load_svg_from_buffer(svg, size / SRC_SIZE)
	if err != OK:
		printerr("rasterise failed (", error_string(err), "): ", svg_path)
		return false
	# ThorVG rounds the scaled extent; force the exact size the presets expect.
	if img.get_width() != size or img.get_height() != size:
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)

	err = img.save_png(out_path)
	if err != OK:
		printerr("write failed (", error_string(err), "): ", out_path)
		return false

	print("%4d px  %s" % [size, out_path])
	return true
