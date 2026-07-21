class_name CameraRig
extends Node3D
## Orbit camera (three.js OrbitControls stand-in): damped drag-to-orbit,
## scroll zoom, right/middle-drag pan, plus the prototype's selection
## behaviour — a 0.9 s eased fly-to when a body is selected, then delta-follow
## so the camera tracks the body while the user keeps full orbit control.
## Touch: one finger orbits, two fingers pinch-zoom and pan, a tap selects.
## Input arrives through the full-screen GestureSurface control (main.gd), so
## the GUI keeps arbitrating pointer events between HUD panels and the camera.
## Tap/click picking is a screen-space disc test with a slop margin.

const MIN_DIST := 4.0
const MAX_DIST := 1200.0
const FLY_TIME := 0.9
const DAMP := 10.0            # exp smoothing rate (≈ OrbitControls damping 0.06)
const TAP_SLOP_MOUSE := 5.0   # max pointer travel (logical px) that still picks
const TAP_SLOP_TOUCH := 16.0
const PICK_SLOP_MOUSE := 8.0  # extra pick radius around a body's disc
const PICK_SLOP_TOUCH := 26.0

var cam: Camera3D

# spherical state around `target` (smoothed toward the *_goal values)
var target := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var dist := 150.0
var yaw_goal := 0.0
var pitch_goal := 0.0
var dist_goal := 150.0

# fly-to animation
var _anim_active := false
var _anim_t := 0.0
var _anim_from_target := Vector3.ZERO
var _anim_from_pos := Vector3.ZERO
var _anim_to_offset := Vector3.ZERO
var _prev_target_pos := Vector3.ZERO

# input tracking
var _rotating := false
var _panning := false
var _down_pos := Vector2.ZERO
var _moved := 0.0
var _touches := {}            # touch index -> last position (logical px)
var _multi_gesture := false   # 2+ fingers seen since last touch-down → no tap

var pick_provider: Callable   # -> Array of {body, pos, radius}

# while the add-body panel is open the camera frames the proposed body
# instead of the selection; the provider yields its live world position
var _preview_provider := Callable()


func _ready() -> void:
	cam = Camera3D.new()
	cam.fov = 50.0
	cam.near = 0.1
	cam.far = 9000.0
	add_child(cam)
	# initial view matches the prototype: camera at (48, 62, 148) looking at origin
	_sync_spherical(Vector3(48, 62, 148), Vector3.ZERO)
	_apply_transform()


func _sync_spherical(cam_pos: Vector3, tgt: Vector3) -> void:
	target = tgt
	var off := cam_pos - tgt
	dist = off.length()
	pitch = asin(clampf(off.y / dist, -1.0, 1.0))
	yaw = atan2(off.x, off.z)
	yaw_goal = yaw
	pitch_goal = pitch
	dist_goal = dist


## real-scale view: the zoom floor drops all the way to a few radii of the
## selected body's TRUE size, so the camera can dive in until the planet's
## real disc fills the screen (the near plane follows in _update_near)
func _min_dist() -> float:
	if not Units.real_scale:
		return MIN_DIST
	var sel = Events.selected
	if sel != null:
		return maxf(BodyView.real_display_radius(sel.radius_km, sel.mass_e) * 2.5, 0.0002)
	return 0.02


## Real scale spans ~7 decades of distance (Neptune's orbit at 210 units down
## to Callisto's 1e-4 disc) — no fixed near plane covers that. Pull the near
## plane in proportionally to the camera-target distance, and pull FAR in with
## it: past a near/far ratio of ~1e7 the renderer's float32 frustum math
## degenerates (light culler fails, whole scene goes black — measured with
## tests/near_probe; ratio 9e6 renders fine, 9e7 doesn't). The starfield
## compensates by shrinking around the camera (Starfield.follow_camera).
func _update_near() -> void:
	if Units.real_scale:
		cam.near = clampf(cam.position.distance_to(target) * 0.1, 2e-5, 0.1)
		cam.far = minf(cam.near * 5e6, 9000.0)
	elif cam.near != 0.1:
		cam.near = 0.1
		cam.far = 9000.0


func _offset() -> Vector3:
	return Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * dist


func _apply_transform() -> void:
	cam.position = target + _offset()
	cam.look_at_from_position(cam.position, target, Vector3.UP)


## Entry point for all pointer input, forwarded from the GestureSurface
## control's gui_input. Touch is handled natively; the mouse events Godot
## synthesizes from touches are ignored so gestures aren't applied twice.
func handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventScreenTouch:
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_on_touch_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventMagnifyGesture:
		# macOS/web trackpad pinch
		var mg := event as InputEventMagnifyGesture
		dist_goal = clampf(dist_goal / maxf(mg.factor, 0.05), _min_dist(), MAX_DIST)
	elif event is InputEventPanGesture:
		# trackpad two-finger scroll → zoom, like the wheel
		var pg := event as InputEventPanGesture
		var f := clampf(1.0 + pg.delta.y * 0.02, 0.5, 2.0)
		dist_goal = clampf(dist_goal * f, _min_dist(), MAX_DIST)


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_rotating = true
			_down_pos = mb.position
			_moved = 0.0
		else:
			_rotating = false
			if _moved <= TAP_SLOP_MOUSE:
				_pick(mb.position, PICK_SLOP_MOUSE)
	elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = mb.pressed
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
		dist_goal = clampf(dist_goal * 0.9, _min_dist(), MAX_DIST)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
		dist_goal = clampf(dist_goal * 1.111, _min_dist(), MAX_DIST)


func _on_mouse_motion(mm: InputEventMouseMotion) -> void:
	if _rotating:
		_moved += mm.relative.length()
		_orbit(mm.relative)
	elif _panning:
		_pan(mm.relative)


func _on_touch(st: InputEventScreenTouch) -> void:
	if st.pressed:
		_touches[st.index] = st.position
		if _touches.size() == 1:
			_multi_gesture = false
			_down_pos = st.position
			_moved = 0.0
		else:
			_multi_gesture = true
	else:
		_touches.erase(st.index)
		if _touches.is_empty() and not _multi_gesture and _moved <= TAP_SLOP_TOUCH:
			_pick(st.position, PICK_SLOP_TOUCH)


func _on_touch_drag(sd: InputEventScreenDrag) -> void:
	if not _touches.has(sd.index):
		return
	var prev: Vector2 = _touches[sd.index]
	if _touches.size() >= 2:
		# incremental pinch: this finger moved, the others are where they were.
		# Separation change zooms, centroid change pans.
		var other := _other_touch_center(sd.index)
		var sep_old := maxf(prev.distance_to(other), 1.0)
		var sep_new := maxf(sd.position.distance_to(other), 1.0)
		dist_goal = clampf(dist_goal * sep_old / sep_new, _min_dist(), MAX_DIST)
		_pan((sd.position - prev) / float(_touches.size()))
	else:
		_moved += sd.relative.length()
		_orbit(sd.relative)
	_touches[sd.index] = sd.position


func _other_touch_center(except_index: int) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for i in _touches:
		if i != except_index:
			sum += _touches[i]
			n += 1
	return sum / float(maxi(n, 1))


func _orbit(rel: Vector2) -> void:
	var vp_h := float(get_viewport().get_visible_rect().size.y)
	yaw_goal -= TAU * rel.x / vp_h
	pitch_goal = clampf(pitch_goal + TAU * rel.y / vp_h, -1.55, 1.55)


func _pan(rel: Vector2) -> void:
	var vp_h := float(get_viewport().get_visible_rect().size.y)
	var pan_scale := dist / vp_h
	var basis_ := cam.global_transform.basis
	target += (-basis_.x * rel.x + basis_.y * rel.y) * pan_scale


## Screen-space picking: a body is hit inside its projected disc plus `slop`
## logical pixels — small/distant planets stay tappable with a finger.
## Direct disc hits win by depth; near-misses fall back to the closest body.
func _pick(screen_pos: Vector2, slop: float) -> void:
	if not pick_provider.is_valid():
		return
	var vp_h := float(get_viewport().get_visible_rect().size.y)
	var px_per_rad := vp_h * 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
	var best_depth := INF
	var best_hit = null
	var best_gap := slop
	var best_near = null
	for c in pick_provider.call():
		if cam.is_position_behind(c.pos):
			continue
		var d := cam.global_position.distance_to(c.pos)
		var screen_r: float = c.radius / maxf(d, 0.001) * px_per_rad
		var gap := cam.unproject_position(c.pos).distance_to(screen_pos) - screen_r
		if gap <= 0.0:
			if d < best_depth:
				best_depth = d
				best_hit = c.body
		elif gap < best_gap:
			best_gap = gap
			best_near = c.body
	var chosen = best_hit if best_hit != null else best_near
	if chosen != null:
		Events.select_requested.emit(chosen)


## current view for snapshots — goal values, so a capture taken mid-damp
## restores where the user was heading, not a transient in-between frame
func view_state() -> Dictionary:
	return { target = target, yaw = yaw_goal, pitch = pitch_goal, dist = dist_goal }


## jump the camera to a saved view (no animation, cancels any fly-to)
func apply_view(tgt: Vector3, yaw_: float, pitch_: float, dist_: float) -> void:
	_anim_active = false
	target = tgt
	_prev_target_pos = tgt
	yaw = yaw_
	yaw_goal = yaw_
	pitch = pitch_
	pitch_goal = pitch_
	dist = clampf(dist_, _min_dist(), MAX_DIST)
	dist_goal = dist
	_apply_transform()


## animate camera to frame the body (called by main on new selection)
func fly_to(body: SimBody) -> void:
	var view_dist := maxf(body.size * 5.5, 7.0)
	if Units.real_scale:
		# land ~60 true radii out: the disc is already visible and the whole
		# moon system fits in frame; scrolling covers the rest of the way in
		view_dist = maxf(BodyView.real_display_radius(body.radius_km, body.mass_e) * 60.0, 0.03)
	_start_fly(view_dist, body.display_pos)


func _start_fly(view_dist: float, to_pos: Vector3) -> void:
	var dir := (cam.position - target).normalized()
	_anim_active = true
	_anim_t = 0.0
	_anim_from_target = target
	_anim_from_pos = cam.position
	_anim_to_offset = dir * view_dist
	_prev_target_pos = to_pos


## start framing the add-panel preview: fly to the proposed position, then
## delta-follow it as the panel's inputs (and the moving anchor) shift it
func focus_preview(provider: Callable, body_size: float) -> void:
	_preview_provider = provider
	var p = provider.call()
	if p != null:
		_start_fly(maxf(body_size * 5.5, 7.0), p)


func preview_focus_active() -> bool:
	return _preview_provider.is_valid()


## panel closed — hand the camera back to the selection without a jump
func end_preview_focus() -> void:
	if not _preview_provider.is_valid():
		return
	_preview_provider = Callable()
	var sel = Events.selected
	if sel != null:
		_prev_target_pos = sel.display_pos
	else:
		_anim_active = false


## what the camera should frame right now: the live preview position while
## the add panel is open, else the selected body, else null (free camera)
func _focus_pos() -> Variant:
	if _preview_provider.is_valid():
		var p = _preview_provider.call()
		if p != null:
			return p
	var sel = Events.selected
	return sel.display_pos if sel != null else null


static func _ease_in_out(t: float) -> float:
	if t < 0.5:
		return 4.0 * t * t * t
	return 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0


func update_camera(dt: float) -> void:
	_update_near()
	var focus = _focus_pos()
	if focus != null:
		var tp: Vector3 = focus
		if _anim_active:
			_anim_t = minf(_anim_t + dt / FLY_TIME, 1.0)
			var k := _ease_in_out(_anim_t)
			target = _anim_from_target.lerp(tp, k)
			var goal := tp + _anim_to_offset
			cam.position = _anim_from_pos.lerp(goal, k)
			cam.look_at_from_position(cam.position, target, Vector3.UP)
			if _anim_t >= 1.0:
				_anim_active = false
				_sync_spherical(cam.position, target)
			_prev_target_pos = tp
			return
		# follow: shift target by the body's motion, keep user's orbit offset
		var delta := tp - _prev_target_pos
		target += delta
		_prev_target_pos = tp

	# damped approach to the input goals
	var k2 := 1.0 - exp(-DAMP * dt)
	yaw = lerpf(yaw, yaw_goal, k2)
	pitch = lerpf(pitch, pitch_goal, k2)
	dist = lerpf(dist, dist_goal, k2)
	_apply_transform()


func camera_distance() -> float:
	return cam.position.length()
