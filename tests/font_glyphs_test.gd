extends Node
## Headless regression test: every icon glyph the UI draws must resolve from
## embedded font resources alone (Font.has_char consults the font + its
## resource fallbacks, NOT OS system fonts — mirroring the web export, where
## no system fonts exist and unresolved glyphs render as tofu boxes).
##   godot --headless --path . res://tests/font_glyphs_test.tscn

# every non-ASCII char used in UI-facing strings (src/ui/*, catalog descs)
const GLYPHS := {
	0x2699: "⚙ settings gear",
	0x2715: "✕ close",
	0x2295: "⊕ earth-mass unit",
	0x21BA: "↺ retrograde spin",
	0x25BE: "▾ expanded row",
	0x25B8: "▸ collapsible row",
	0x2190: "← back",
	0x22EF: "⋯ overflow menu",
	0x00B7: "· dot separator",
	0x00D7: "× multiplier",
	0x00B0: "° degrees",
	0x207B: "⁻ superscript minus",
	0x00B3: "³ cubed",
	0x2082: "₂ CO₂ subscript",
	0x2014: "— em dash",
	0x201C: "“ curly quote",
	0x201D: "” curly quote",
}

var _failed := false


func _ready() -> void:
	var font := ThemeDB.fallback_font
	_check(font != null, "default theme font exists")
	for cp: int in GLYPHS:
		_check(font.has_char(cp), "U+%04X %s" % [cp, GLYPHS[cp]])
	if _failed:
		print("[font_glyphs] FAILED")
		get_tree().quit(1)
	else:
		print("[font_glyphs] ALL PASSED")
		get_tree().quit(0)


func _check(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok " if ok else "FAIL", what])
	if not ok:
		_failed = true
