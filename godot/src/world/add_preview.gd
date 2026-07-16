class_name AddPreview
extends Node3D
## Live 3D preview for the add-body panel: wireframe sphere at the injection
## point, faint circle at the chosen orbital distance, and the starting
## velocity vector. Follows the sun (placement inputs are sun-relative).

const WIRE_SHADER := preload("res://src/gfx/wireframe.gdshader")

var _sphere: MeshInstance3D
var _ring: MeshInstance3D
var _arrow: VelocityArrow
var _cfg = null   # Dictionary or null (hidden)


func _ready() -> void:
	visible = false

	var smesh := SphereMesh.new()
	smesh.radius = 1.0
	smesh.height = 2.0
	smesh.radial_segments = 24
	smesh.rings = 12
	var smat := ShaderMaterial.new()
	smat.shader = WIRE_SHADER
	smat.set_shader_parameter("wire_color", Color(159 / 255.0, 214 / 255.0, 1.0, 0.55))
	_sphere = MeshInstance3D.new()
	_sphere.mesh = smesh
	_sphere.material_override = smat
	add_child(_sphere)

	# unit circle in the ecliptic, scaled to the chosen distance
	var pts := PackedVector3Array()
	for k in 161:
		var a := (float(k) / 160.0) * TAU
		pts.append(Vector3(cos(a), 0, sin(a)))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	var rmesh := ArrayMesh.new()
	rmesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(1, 1, 1, 0.13)
	_ring = MeshInstance3D.new()
	_ring.mesh = rmesh
	_ring.material_override = rmat
	_ring.custom_aabb = AABB(Vector3(-500, -500, -500), Vector3(1000, 1000, 1000))
	add_child(_ring)

	_arrow = VelocityArrow.new()
	_arrow.setup(Color("6cc4ff"))
	add_child(_arrow)

	Events.add_preview_changed.connect(_on_preview_changed)


func _on_preview_changed(cfg) -> void:
	_cfg = cfg
	visible = cfg != null
	if cfg != null:
		_apply(cfg)


func _apply(cfg: Dictionary) -> void:
	var st := NBodySystem.state_vector_from_inputs(cfg)
	var p := Units.to_display(Vector3(st.p[0], st.p[1], st.p[2]))
	_sphere.scale = Vector3.ONE * clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.35, 3.4)
	_sphere.position = p
	_ring.scale = Vector3.ONE * Units.dist_scale(cfg.dist_au)
	_arrow.position = p
	var v := Vector3(st.v[0], st.v[1], st.v[2])
	if v.length_squared() > 1e-14:
		_arrow.set_direction(v)
	var vlen: float = clampf(2.5 + cfg.speed_kms * 0.3, 2.5, 26.0)
	_arrow.set_arrow_length(vlen, vlen * 0.22, vlen * 0.13)
	_arrow.visible = cfg.speed_kms > 0.0


## placement inputs are sun-relative — keep the preview anchored to the sun
func follow_sun(sun_pos: Vector3) -> void:
	if visible:
		position = sun_pos
