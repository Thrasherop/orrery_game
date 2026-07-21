class_name VelocityArrow
extends Node3D
## three.js ArrowHelper equivalent: thin shaft + cone head built along +Y,
## oriented with set_direction and sized with set_arrow_length.

var _shaft: MeshInstance3D
var _head: MeshInstance3D
var _len := 6.0
var _head_len := 1.6


func setup(color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color

	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.04
	shaft_mesh.bottom_radius = 0.04
	shaft_mesh.height = 1.0
	shaft_mesh.radial_segments = 6
	_shaft = MeshInstance3D.new()
	_shaft.mesh = shaft_mesh
	_shaft.material_override = mat
	add_child(_shaft)

	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.5
	head_mesh.height = 1.0
	head_mesh.radial_segments = 12
	_head = MeshInstance3D.new()
	_head.mesh = head_mesh
	_head.material_override = mat
	add_child(_head)

	set_arrow_length(6.0, 1.6, 0.9)


func set_arrow_length(length: float, head_len: float, head_width: float) -> void:
	_len = length
	_head_len = head_len
	var shaft_len := maxf(length - head_len, 0.01)
	_shaft.scale = Vector3(1, shaft_len, 1)
	_shaft.position = Vector3(0, shaft_len / 2.0, 0)
	_head.scale = Vector3(head_width, head_len, head_width)
	_head.position = Vector3(0, shaft_len + head_len / 2.0, 0)


func set_direction(dir: Vector3) -> void:
	if dir.length_squared() < 1e-14:
		return
	var d := dir.normalized()
	if d.is_equal_approx(Vector3.UP):
		basis = Basis.IDENTITY
	elif d.is_equal_approx(Vector3.DOWN):
		basis = Basis(Vector3.RIGHT, PI)
	else:
		basis = Basis(Quaternion(Vector3.UP, d))
