class_name LabelsLayer
extends CanvasLayer
## Screen-projected clickable body labels. Hidden when the body is behind the
## camera, off screen, currently selected, or labels are toggled off.

var sim: Simulation
var rig: CameraRig
var _root: Control
var _labels := {}   # SimBody -> Button


func setup(sim_: Simulation, rig_: CameraRig) -> void:
	sim = sim_
	rig = rig_
	layer = 2
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	rebuild()
	Events.bodies_changed.connect(rebuild)


func rebuild() -> void:
	for b in _labels:
		_labels[b].queue_free()
	_labels.clear()
	for b in sim.all_bodies():
		var btn := Button.new()
		btn.text = b.body_name.to_upper()
		btn.focus_mode = Control.FOCUS_NONE
		btn.flat = true
		btn.add_theme_font_size_override("font_size", UITheme.fs(10))
		btn.add_theme_color_override("font_color", b.color)
		btn.add_theme_color_override("font_hover_color", UITheme.ACCENT)
		for st in ["normal", "hover", "pressed"]:
			var sbe := StyleBoxEmpty.new()
			if UITheme.touch:
				sbe.set_content_margin_all(8)   # fatter finger target
			btn.add_theme_stylebox_override(st, sbe)
		btn.modulate.a = 0.85
		var body: SimBody = b
		btn.pressed.connect(func() -> void: Events.select_requested.emit(body))
		_root.add_child(btn)
		_labels[b] = btn


func update_labels() -> void:
	var vp_size := _root.get_viewport_rect().size
	for b in _labels:
		var btn: Button = _labels[b]
		if not Events.show_labels:
			btn.visible = false
			continue
		var world_pos: Vector3 = b.display_pos
		var behind := rig.cam.is_position_behind(world_pos)
		if behind:
			btn.visible = false
			continue
		var sp := rig.cam.unproject_position(world_pos)
		var off := sp.x < -60.0 or sp.x > vp_size.x + 60.0 or sp.y < -60.0 or sp.y > vp_size.y + 60.0
		if off or Events.selected == b:
			btn.visible = false
			continue
		btn.visible = true
		btn.position = sp - Vector2(btn.size.x / 2.0, btn.size.y + 14.0)
