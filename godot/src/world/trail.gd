class_name TrailView
extends MeshInstance3D
## Renders a SimBody's ring-buffer trail as an additive line strip. The
## buffer lives on the SimBody; this view rebuilds its mesh only when the
## trail version changes (one cheap array copy).

var body: SimBody
var mat: StandardMaterial3D
var _last_version := -1


func setup(b: SimBody) -> void:
	body = b
	name = b.body_name + "Trail"
	mesh = ArrayMesh.new()
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material_override = mat
	custom_aabb = AABB(Vector3(-2000, -2000, -2000), Vector3(4000, 4000, 4000))
	set_opacity(b.trail_opacity)


## Godot's additive blend ignores alpha (three.js multiplies by it),
## so bake the opacity into the color instead.
func set_opacity(a: float) -> void:
	mat.albedo_color = Color(body.color.r * a, body.color.g * a, body.color.b * a, 1.0)


func refresh() -> void:
	if body.trail_version == _last_version:
		return
	_last_version = body.trail_version
	var am := mesh as ArrayMesh
	am.clear_surfaces()
	if body.trail_points.size() < 2:
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = body.trail_points
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)
