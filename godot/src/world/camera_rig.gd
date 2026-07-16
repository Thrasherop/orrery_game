class_name CameraRig
extends Node3D
## Orbit camera (three.js OrbitControls stand-in): damped drag-to-orbit,
## scroll zoom, right/middle-drag pan, plus the prototype's selection
## behaviour — a 0.9 s eased fly-to when a body is selected, then delta-follow
## so the camera tracks the body while the user keeps full orbit control.
## Also does click picking via manual ray-vs-sphere tests.

const MIN_DIST := 4.0
const MAX_DIST := 1200.0
const FLY_TIME := 0.9
const DAMP := 10.0            # exp smoothing rate (≈ OrbitControls damping 0.06)

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

var pick_provider: Callable   # -> Array of {body, pos, radius}


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


func _offset() -> Vector3:
	return Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * dist


func _apply_transform() -> void:
	cam.position = target + _offset()
	cam.look_at_from_position(cam.position, target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_rotating = true
				_down_pos = mb.position
				_moved = 0.0
			else:
				_rotating = false
				if _moved <= 5.0:
					_pick(mb.position)
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			dist_goal = clampf(dist_goal * 0.9, MIN_DIST, MAX_DIST)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			dist_goal = clampf(dist_goal * 1.111, MIN_DIST, MAX_DIST)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var vp_h := float(get_viewport().get_visible_rect().size.y)
		if _rotating:
			_moved += mm.relative.length()
			yaw_goal -= TAU * mm.relative.x / vp_h
			pitch_goal = clampf(pitch_goal + TAU * mm.relative.y / vp_h, -1.55, 1.55)
		elif _panning:
			var pan_scale := dist / vp_h
			var basis_ := cam.global_transform.basis
			target += (-basis_.x * mm.relative.x + basis_.y * mm.relative.y) * pan_scale


func _pick(screen_pos: Vector2) -> void:
	if not pick_provider.is_valid():
		return
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var best_t := INF
	var best_body = null
	for c in pick_provider.call():
		var oc: Vector3 = origin - c.pos
		var b := oc.dot(dir)
		var disc: float = b * b - (oc.length_squared() - c.radius * c.radius)
		if disc < 0.0:
			continue
		var t := -b - sqrt(disc)
		if t < 0.0:
			t = -b + sqrt(disc)
		if t >= 0.0 and t < best_t:
			best_t = t
			best_body = c.body
	if best_body != null:
		Events.select_requested.emit(best_body)


## animate camera to frame the body (called by main on new selection)
func fly_to(body: SimBody) -> void:
	var d := maxf(body.size * 5.5, 7.0)
	var dir := (cam.position - target).normalized()
	_anim_active = true
	_anim_t = 0.0
	_anim_from_target = target
	_anim_from_pos = cam.position
	_anim_to_offset = dir * d
	_prev_target_pos = body.display_pos


static func _ease_in_out(t: float) -> float:
	if t < 0.5:
		return 4.0 * t * t * t
	return 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0


func update_camera(dt: float) -> void:
	var selected = Events.selected
	if selected != null:
		var tp: Vector3 = selected.display_pos
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
