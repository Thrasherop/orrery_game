class_name EdgeDrawer
extends Container
## Samsung-edge-panel-style wrapper: hosts one panel plus a slim chevron tab on
## the panel's inner side. Tapping the tab slides the panel off its screen edge
## (the tab stays clamped at the edge) and back out again. The drawer itself is
## input-transparent — only the panel and the tab receive pointer events, so a
## tucked-away drawer never blocks camera gestures.

enum Edge { LEFT, RIGHT, TOP, BOTTOM }

const SLIDE_TIME := 0.25
const OVERSHOOT := 64.0   # extra travel so panel shadow + edge gap fully clear

var edge := Edge.LEFT
var is_open := true

var _content: Control
var _handle: Button
var _slide := 0.0         # 0 = open, 1 = tucked away
var _tween: Tween


func _init(edge_: Edge, content: Control, tip := "Hide / show") -> void:
	edge = edge_
	_content = content
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(_content)

	_handle = Button.new()
	_handle.focus_mode = Control.FOCUS_NONE
	_handle.tooltip_text = tip
	UITheme.style_drawer_handle(_handle)
	_handle.pressed.connect(toggle)
	_handle.draw.connect(_draw_arrow)
	add_child(_handle)


func toggle() -> void:
	set_open(not is_open)


func set_open(on: bool, animate := true) -> void:
	is_open = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var goal := 0.0 if on else 1.0
	if not animate or not is_inside_tree():
		_slide = goal
		queue_sort()
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(func(v: float) -> void:
		_slide = v
		queue_sort(), _slide, goal, SLIDE_TIME)


func _horizontal() -> bool:
	return edge == Edge.LEFT or edge == Edge.RIGHT


func _handle_size() -> Vector2:
	var thick := 26.0 if UITheme.touch else 18.0
	var length := 84.0 if UITheme.touch else 56.0
	return Vector2(thick, length) if _horizontal() else Vector2(length, thick)


func _get_minimum_size() -> Vector2:
	if _content == null:
		return Vector2.ZERO
	var m := _content.get_combined_minimum_size()
	var hs := _handle_size()
	if _horizontal():
		return Vector2(m.x + hs.x, maxf(m.y, hs.y))
	return Vector2(maxf(m.x, hs.x), m.y + hs.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_sort_drawer()


func _sort_drawer() -> void:
	var m := _content.get_combined_minimum_size()
	var hs := _handle_size()
	var gp := get_global_rect().position
	var vp := get_viewport_rect().size
	var travel := ((m.x if _horizontal() else m.y) + OVERSHOOT) * _slide
	match edge:
		Edge.LEFT:
			var cx := -travel
			fit_child_in_rect(_content, Rect2(Vector2(cx, 0), m))
			var hx := maxf(cx + m.x, -gp.x)   # ride along, stop at screen edge
			fit_child_in_rect(_handle, Rect2(Vector2(hx, (m.y - hs.y) * 0.5), hs))
		Edge.RIGHT:
			var cx := hs.x + travel
			fit_child_in_rect(_content, Rect2(Vector2(cx, 0), m))
			var hx := minf(cx - hs.x, vp.x - gp.x - hs.x)
			fit_child_in_rect(_handle, Rect2(Vector2(hx, (m.y - hs.y) * 0.5), hs))
		Edge.TOP:
			var cy := -travel
			fit_child_in_rect(_content, Rect2(Vector2(0, cy), m))
			var hy := maxf(cy + m.y, -gp.y)
			fit_child_in_rect(_handle, Rect2(Vector2((m.x - hs.x) * 0.5, hy), hs))
		Edge.BOTTOM:
			var cy := hs.y + travel
			fit_child_in_rect(_content, Rect2(Vector2(0, cy), m))
			var hy := minf(cy - hs.y, vp.y - gp.y - hs.y)
			fit_child_in_rect(_handle, Rect2(Vector2((m.x - hs.x) * 0.5, hy), hs))
	_handle.queue_redraw()


## chevron pointing where a tap will move the panel: outward while open
## ("tuck away"), inward while tucked ("pull out")
func _draw_arrow() -> void:
	var c: Vector2 = _handle.size * 0.5
	var s := 7.0 if UITheme.touch else 5.0
	var out := Vector2.ZERO
	match edge:
		Edge.LEFT: out = Vector2.LEFT
		Edge.RIGHT: out = Vector2.RIGHT
		Edge.TOP: out = Vector2.UP
		Edge.BOTTOM: out = Vector2.DOWN
	var dir := out if is_open else -out
	var perp := Vector2(-dir.y, dir.x)
	var tip := c + dir * s * 0.5
	var back := c - dir * s * 0.5
	var color := UITheme.TEXT if _handle.is_hovered() else UITheme.MUTED
	_handle.draw_polyline(
		PackedVector2Array([back + perp * s, tip, back - perp * s]), color, 2.0, true)
