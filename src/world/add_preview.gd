class_name AddPreview
extends Node3D
## Live 3D preview for the add-body panel: wireframe sphere at the injection
## point, faint circle at the chosen orbital distance — tilted into the plane
## the orbit would actually lie in — and the starting velocity vector.
## Rides on its anchor (the sun, or the host body when placing a moon).

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
	var host = cfg.get("host", null)
	var p: Vector3
	var ring_r: float
	if host != null:
		# moon placement: same linear amplification the moon will render with,
		# so the wireframe sits exactly where the moon will appear (true offset
		# in the real-scale view)
		var k: float = Units.REAL_AU if Units.real_scale else MoonMath.add_disp_k(host.size, cfg.dist_au)
		p = Vector3(st.p[0], st.p[1], st.p[2]) * k
		_sphere.scale = Vector3.ONE * clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.12, 1.2)
		ring_r = cfg.dist_au * k
	else:
		p = Units.render(Vector3(st.p[0], st.p[1], st.p[2]))
		_sphere.scale = Vector3.ONE * clampf(0.9 * pow(cfg.mass_e, 1.0 / 3.0), 0.35, 3.4)
		ring_r = Units.render_scale(cfg.dist_au)
	# tilt the guide circle into the plane the orbit would actually lie in —
	# spanned by the (anchor-relative) position and launch velocity — so it
	# always passes through the injection point, whatever the latitude
	var pr := Vector3(st.p[0], st.p[1], st.p[2])
	var vv := Vector3(st.v[0], st.v[1], st.v[2])
	var x_axis := pr.normalized()
	var normal := pr.cross(vv)
	if normal.length_squared() < 1e-16:
		# zero or purely radial velocity picks no plane — assume the
		# horizontal prograde direction the panel's 0° corresponds to
		var th: float = cfg.lon_deg * Units.DEG
		normal = pr.cross(Vector3(-sin(th), 0.0, -cos(th)))
	if normal.length_squared() < 1e-16:
		normal = Vector3.UP
	normal = normal.normalized()
	_ring.basis = Basis(x_axis * ring_r, normal * ring_r, x_axis.cross(normal) * ring_r)
	_sphere.position = p
	_arrow.position = p
	var v := Vector3(st.v[0], st.v[1], st.v[2])
	if v.length_squared() > 1e-14:
		_arrow.set_direction(v)
	var vlen: float = clampf(2.5 + cfg.speed_kms * 0.3, 2.5, 26.0)
	_arrow.set_arrow_length(vlen, vlen * 0.22, vlen * 0.13)
	_arrow.visible = cfg.speed_kms > 0.0


## placement inputs are relative to the sun — or to the host body when
## adding a moon — so the whole preview rides on that anchor
func follow_anchor(sun_pos: Vector3) -> void:
	var host = _cfg.get("host", null) if _cfg != null else null
	position = host.display_pos if host != null else sun_pos


## world-space position of the previewed body (null while hidden) — the
## camera rig frames this point while the add panel is open
func focus_position() -> Variant:
	if not visible or _cfg == null:
		return null
	return position + _sphere.position


func focus_size() -> float:
	return _sphere.scale.x
