class_name MobileSheet
extends Control
## The mobile HUD's core surface: a bottom sheet that slides up from the screen
## edge, Android-style. Modal sheets add a tap-to-dismiss scrim; non-modal
## sheets (the body card) leave the rest of the screen interactive. A sheet
## with `peek_height > 0` gets two snap states — collapsed "peek" and full —
## and the grabber can be dragged (or tapped) between them; dragging below
## peek dismisses the sheet. Content lives in `content` and scrolls once it
## exceeds the height cap.

signal closed
signal state_snapped(state: int)

enum State { HIDDEN, PEEK, FULL }

const SLIDE_TIME := 0.26
const MAX_WIDTH := 560.0   # logical px cap so tablets don't get wall-to-wall sheets
const FLING_DY := 7.0      # px/event: treat release as a fling in that direction
const TAP_SLOP := 8.0      # drags shorter than this count as a tap on the grabber
const GRABBER_H := 26.0

var modal := true
var peek_height := 0.0     # > 0 enables the collapsed snap state
var max_ratio := 0.62      # FULL height cap as a fraction of the viewport
var bottom_inset := 0.0    # keeps the sheet above the action bar (non-modal sheets)
var dismissible := true    # false: swiping down stops at peek — only code close()s
var suppressed := false    # temporarily invisible without losing its snap state

var state: int = State.HIDDEN
var content: VBoxContainer

var _scrim: ColorRect
var _panel: PanelContainer
var _col: VBoxContainer
var _grabber: Control
var _scroll: ScrollContainer
var _footer: Control
var _shown := 0.0          # currently revealed panel height (animated / dragged)
var _tween: Tween
var _dragging := false
var _drag_from := 0.0
var _drag_shown0 := 0.0
var _last_dy := 0.0


func _init(modal_ := true, peek := 0.0) -> void:
	modal = modal_
	peek_height = peek
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	if modal:
		_scrim = ColorRect.new()
		_scrim.color = Color(0, 0, 0, 0.55)
		_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		_scrim.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb != null and mb.pressed:
				close())
		add_child(_scrim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.sheet_style())
	_panel.clip_contents = true
	add_child(_panel)

	_col = VBoxContainer.new()
	_col.add_theme_constant_override("separation", 4)
	_panel.add_child(_col)

	_grabber = Control.new()
	_grabber.custom_minimum_size = Vector2(0, GRABBER_H)
	_grabber.draw.connect(_draw_grabber)
	_grabber.gui_input.connect(_on_grabber_input)
	_col.add_child(_grabber)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col.add_child(_scroll)
	# forms are dense with sliders/edits that swallow touch pans, so keep a
	# visible, touch-sized scrollbar as the always-reliable scroll handle
	var vsb := _scroll.get_v_scroll_bar()
	vsb.custom_minimum_size.x = 14   # draggable with a fingertip
	var track := StyleBoxEmpty.new()
	vsb.add_theme_stylebox_override("scroll", track)
	vsb.add_theme_stylebox_override("scroll_focus", track)
	for st in [["grabber", 0.18], ["grabber_highlight", 0.3], ["grabber_pressed", 0.36]]:
		var g := StyleBoxFlat.new()
		g.bg_color = Color(1, 1, 1, st[1])
		g.set_corner_radius_all(5)
		vsb.add_theme_stylebox_override(st[0], g)

	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(content)


func _process(_dt: float) -> void:
	if visible:
		_layout()


func open(to_full := false) -> void:
	_snap_to(State.FULL if (to_full or peek_height <= 0.0) else State.PEEK)


func close() -> void:
	if not visible and state == State.HIDDEN:
		return
	_snap_to(State.HIDDEN)


func expand() -> void:
	_snap_to(State.FULL)


func collapse() -> void:
	if peek_height > 0.0:
		_snap_to(State.PEEK)


func is_open() -> bool:
	return state != State.HIDDEN


## hide/show without touching the snap state or emitting `closed` — used when
## another sheet takes the bottom edge (e.g. the add form over the body card)
func set_suppressed(on: bool) -> void:
	if suppressed == on:
		return
	suppressed = on
	visible = not on and state != State.HIDDEN


## convenience: a standard sheet title at the top of `content`
func add_title(text: String) -> Label:
	var l := UITheme.make_label(text, 15, UITheme.TEXT)
	content.add_child(l)
	return l


## pins a control below the scroll area — critical actions (Add/Cancel) stay
## reachable without scrolling the content. Hidden at peek, where only the
## title strip shows.
func set_footer(c: Control) -> void:
	# hairline divider so pinned actions read as chrome, not as the next row
	var rule := Panel.new()
	rule.custom_minimum_size = Vector2(0, 1)
	var rsb := StyleBoxFlat.new()
	rsb.bg_color = Color(1, 1, 1, 0.08)
	rule.add_theme_stylebox_override("panel", rsb)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 8)
	wrap.add_child(rule)
	wrap.add_child(c)
	_footer = wrap
	_col.add_child(wrap)


func _full_height() -> float:
	var vp := get_viewport_rect().size
	var sb := _panel.get_theme_stylebox("panel")
	var chrome := GRABBER_H + 4.0 + sb.content_margin_top + sb.content_margin_bottom
	if _footer != null:
		chrome += _footer.get_combined_minimum_size().y + 4.0
	var need := content.get_combined_minimum_size().y + chrome
	var cap := vp.y * max_ratio - bottom_inset
	return clampf(need, minf(peek_height, cap), cap)


func _height_for(st: int) -> float:
	match st:
		State.HIDDEN:
			return 0.0
		State.PEEK:
			return peek_height
	return _full_height()


func _layout() -> void:
	var vp := get_viewport_rect().size
	var animating := _tween != null and _tween.is_valid() and _tween.is_running()
	if not _dragging and not animating:
		_shown = _height_for(state)
	var w := minf(vp.x, MAX_WIDTH)
	_panel.visible = _shown > 0.5
	# the pinned footer only appears once the sheet is meaningfully taller
	# than its peek strip (at peek just the title shows)
	if _footer != null:
		_footer.visible = _shown > peek_height + 60.0
	_panel.size = Vector2(w, maxf(_shown, _panel.get_combined_minimum_size().y))
	_panel.position = Vector2((vp.x - w) * 0.5, vp.y - bottom_inset - _shown)


func _snap_to(st: int) -> void:
	var was := state
	state = st
	var goal := _height_for(st)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if not is_inside_tree():
		_shown = goal
		visible = st != State.HIDDEN and not suppressed
		if _scrim != null:
			_scrim.modulate.a = 1.0 if st != State.HIDDEN else 0.0
		if st == State.HIDDEN and was != State.HIDDEN:
			closed.emit()
		return
	visible = not suppressed
	if _scrim != null:
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if st != State.HIDDEN \
			else Control.MOUSE_FILTER_IGNORE
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.set_parallel(true)
	if _scrim != null:
		_tween.tween_property(_scrim, "modulate:a", 0.0 if st == State.HIDDEN else 1.0, SLIDE_TIME)
	_tween.tween_method(func(v: float) -> void:
		_shown = v
		_layout(), _shown, goal, SLIDE_TIME)
	_tween.chain().tween_callback(func() -> void:
		if state == State.HIDDEN:
			visible = false
			closed.emit())
	if st != was:
		state_snapped.emit(st)


func _on_grabber_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_dragging = true
			_drag_from = mb.global_position.y
			_drag_shown0 = _shown
			_last_dy = 0.0
		elif _dragging:
			_dragging = false
			_end_drag(mb.global_position.y)
		return
	var mm := ev as InputEventMouseMotion
	if mm != null and _dragging:
		_last_dy = mm.relative.y
		_shown = clampf(_drag_shown0 + (_drag_from - mm.global_position.y), 0.0, _full_height())
		_layout()


func _end_drag(release_y: float) -> void:
	if absf(release_y - _drag_from) < TAP_SLOP:
		# tap on the grabber: toggle peek <-> full
		if peek_height > 0.0:
			_snap_to(State.FULL if state == State.PEEK else State.PEEK)
		else:
			_snap_to(State.FULL)   # settle back
		return
	var full := _full_height()
	var target: int
	if _last_dy > FLING_DY:      # flung down
		target = State.PEEK if peek_height > 0.0 and _shown > peek_height else State.HIDDEN
	elif _last_dy < -FLING_DY:   # flung up
		target = State.FULL
	else:                        # settle to the nearest snap point
		target = State.HIDDEN
		var best := _shown
		if peek_height > 0.0 and absf(_shown - peek_height) < best:
			best = absf(_shown - peek_height)
			target = State.PEEK
		if absf(_shown - full) < best:
			target = State.FULL
	# a non-dismissible sheet (in-progress form) tucks to peek, never away
	if target == State.HIDDEN and not dismissible:
		target = State.PEEK if peek_height > 0.0 else State.FULL
	_snap_to(target)


func _draw_grabber() -> void:
	var w := 44.0
	var r := Rect2((_grabber.size.x - w) * 0.5, 11.0, w, 5.0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.22)
	sb.set_corner_radius_all(3)
	_grabber.draw_style_box(sb, r)
