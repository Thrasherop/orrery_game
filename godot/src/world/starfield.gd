class_name Starfield
extends Node3D
## Three point-cloud layers (two uniform shells + a 9,000-star milky-way band
## scattered gaussianly around a plane tilted 1.05 rad) plus faint additive
## nebula wisps along the galactic band. Slowly rotates.

const STAR_SHADER := preload("res://src/gfx/star_points.gdshader")

const TINTS := [
	Vector3(1, 1, 1), Vector3(0.75, 0.83, 1), Vector3(1, 0.94, 0.8),
	Vector3(1, 0.82, 0.64), Vector3(0.85, 0.9, 1),
]

var _layers: Array = []   # { mat: ShaderMaterial, base: float } per point layer
var _shrink := 1.0        # last applied follow_camera scale


func _ready() -> void:
	add_child(_star_points(7000, { size = 3.2, opacity = 0.95 }))
	add_child(_star_points(3000, { size = 5.5, opacity = 0.8 }))
	add_child(_star_points(9000, { size = 2.4, opacity = 0.55, band = true, dim = true }))
	_add_nebulae()


func update_rotation(dt: float) -> void:
	rotate_y(dt * 0.0022)


## The real-scale view shrinks the camera's far plane during deep zooms (see
## CameraRig._update_near) — far below the 2200–4000-unit star shell. Stars
## are effectively at infinity, so shrinking the whole field around the CAMERA
## is visually identical and keeps it inside the frustum: world = c(1-s) + s·orig.
## The point shader sizes stars by 1/distance, so size_px scales by s too —
## the on-screen result is pixel-identical to the unshrunk field.
func follow_camera(cam_pos: Vector3, far: float) -> void:
	var s := minf(far * 0.9 / 4000.0, 1.0)
	scale = Vector3.ONE * s
	position = cam_pos * (1.0 - s)
	if absf(s - _shrink) > 0.001:
		_shrink = s
		for l in _layers:
			l.mat.set_shader_parameter("size_px", l.base * s)


func _star_points(count: int, opts: Dictionary) -> MeshInstance3D:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	pos.resize(count)
	col.resize(count)
	for i in count:
		var v: Vector3
		if opts.get("band", false):
			# gaussian scatter around a tilted plane → milky way
			var th := randf() * TAU
			var g := (randf() + randf() + randf() - 1.5) / 1.5
			v = Vector3(cos(th), g * 0.16, sin(th)).normalized()
			v = v.rotated(Vector3(1, 0, 0), 1.05)
		else:
			v = Vector3(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0, randf() * 2.0 - 1.0).normalized()
		var r := 2200.0 + randf() * 1800.0
		pos[i] = v * r
		var t: Vector3 = TINTS[randi() % TINTS.size()]
		var b := (0.3 + randf() * 0.4) if opts.get("dim", false) else (0.55 + randf() * 0.45)
		col[i] = Color(t.x * b, t.y * b, t.z * b)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_COLOR] = col
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)

	var mat := ShaderMaterial.new()
	mat.shader = STAR_SHADER
	mat.set_shader_parameter("size_px", opts["size"])   # ["size"] — dot access hits Dictionary.size()
	mat.set_shader_parameter("opacity", opts.opacity)
	_layers.append({ mat = mat, base = opts["size"] })

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(-4200, -4200, -4200), Vector3(8400, 8400, 8400))
	return mi


## faint nebula wisps along the galactic band
func _add_nebulae() -> void:
	var neb_cols := [
		Color(96 / 255.0, 110 / 255.0, 220 / 255.0, 0.5),
		Color(70 / 255.0, 140 / 255.0, 180 / 255.0, 0.45),
		Color(150 / 255.0, 90 / 255.0, 190 / 255.0, 0.4),
	]
	for i in 9:
		var tex := TextureFactory.make_glow(neb_cols[i % 3], Color(20 / 255.0, 25 / 255.0, 60 / 255.0, 0.18))
		var mat := SunView.make_glow_material(
			preload("res://src/gfx/glow_billboard.gdshader"),
			tex, Color.WHITE, 0.05 + randf() * 0.05)
		var mi := SunView.make_glow_sprite(mat, 900.0 + randf() * 1400.0)
		var th := randf() * TAU
		var v := Vector3(cos(th), (randf() - 0.5) * 0.25, sin(th)).normalized()
		mi.position = v.rotated(Vector3(1, 0, 0), 1.05) * 2600.0
		add_child(mi)
