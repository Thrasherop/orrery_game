class_name ConfirmPanel
extends CanvasLayer
## Themed modal confirmation. Code-built on purpose: Godot's native
## ConfirmationDialog is a separate OS Window that ignores UITheme and the
## UX content_scale_factor, so it would look alien on phones and web.

signal answered(ok: bool)

var _panel_width := 340.0


## Fire-and-forget: builds the dialog, parents it, frees itself on answer.
static func ask(parent: Node, title: String, body: String, confirm_text := "OK",
		destructive := false, on_confirm := Callable()) -> void:
	var p := ConfirmPanel.new()
	p._build(title, body, confirm_text, destructive)
	if on_confirm.is_valid():
		p.answered.connect(func(ok: bool) -> void:
			if ok:
				on_confirm.call())
	parent.add_child(p)


func _build(title: String, body: String, confirm_text: String, destructive: bool) -> void:
	layer = 5   # above the HUD (3) and the save browser (4)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title_lbl := UITheme.make_label(title, 15, UITheme.TEXT)
	box.add_child(title_lbl)

	var body_lbl := UITheme.make_label(body, 12, UITheme.MUTED)
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_lbl.custom_minimum_size = Vector2(_panel_width, 0)
	box.add_child(body_lbl)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	box.add_child(actions)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UITheme.style_ghost(cancel)
	cancel.pressed.connect(func() -> void: _answer(false))
	actions.add_child(cancel)

	var confirm := Button.new()
	confirm.text = confirm_text
	confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if destructive:
		UITheme.style_danger(confirm)
	else:
		UITheme.style_primary(confirm)
	confirm.pressed.connect(func() -> void: _answer(true))
	actions.add_child(confirm)

	if UITheme.touch:
		for b in [cancel, confirm]:
			(b as Button).custom_minimum_size = Vector2(0, 46)


func _answer(ok: bool) -> void:
	answered.emit(ok)
	queue_free()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_answer(false)
