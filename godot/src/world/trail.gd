class_name TrailView
extends MeshInstance3D
## Renders a SimBody's ring-buffer trail as an additive line strip. The
## buffer lives on the SimBody (cached per-mode vertices, see TrailFrames);
## this view rebuilds its mesh only when the trail version changes (one
## cheap array copy). SolarSystemView positions it every frame at the
## active frame's anchor.
##
## The strip ends at the NEWEST SAMPLE, which can lag the body by up to one
## sample interval — invisible zoomed out, but up close the line would end
## behind the planet and extend in discrete jumps. A separate 2-vertex head
## segment (rebuilt every frame, it's tiny) bridges the newest sample to the
## body's live position so the trail stays continuously glued to it.

var body: SimBody
var mat: StandardMaterial3D
var _last_version := -1
var _head: MeshInstance3D


func setup(b: SimBody) -> void:
	body = b
	name = b.body_name + "Trail"
	mesh = ArrayMesh.new()
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material_override = mat
	# galaxy-mode vertices carry a +GAL_V*day term, which parks the mesh's
	# local geometry tens of thousands of units from its origin — the AABB
	# must cover that or the strip gets frustum-culled
	custom_aabb = AABB(Vector3(-90000, -90000, -90000), Vector3(180000, 180000, 180000))
	_head = MeshInstance3D.new()
	_head.mesh = ArrayMesh.new()
	_head.material_override = mat
	_head.custom_aabb = custom_aabb
	add_child(_head)
	set_opacity(b.trail_opacity)


## Godot's additive blend ignores alpha (three.js multiplies by it),
## so bake the opacity into the color instead.
func set_opacity(a: float) -> void:
	mat.albedo_color = Color(body.color.r * a, body.color.g * a, body.color.b * a, 1.0)


func refresh() -> void:
	_refresh_head()
	if body.trail_version == _last_version:
		return
	_last_version = body.trail_version
	var am := mesh as ArrayMesh
	am.clear_surfaces()
	var pts := body.trail_verts
	# galaxy mode: window to the recent past — an outer planet's 2-orbit
	# buffer spans centuries and would smear thousands of units across space
	if TrailFrames.mode == TrailFrames.MODE_GALAXY and body.trail_days.size() > 1:
		var last := body.trail_days.size() - 1
		var cut := body.trail_days.bsearch(body.trail_days[last] - TrailFrames.GAL_WINDOW_DAYS)
		if cut > 0:
			pts = pts.slice(cut)
	if pts.size() < 2:
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)


## live segment: newest sample vertex → the body's current position, in the
## mesh's frame-local space (our own `position` is this frame's anchor_now,
## set by SolarSystemView just before refresh)
func _refresh_head() -> void:
	var am := _head.mesh as ArrayMesh
	am.clear_surfaces()
	var n := body.trail_verts.size()
	if n == 0:
		return
	var pts := PackedVector3Array()
	pts.resize(2)
	pts[0] = body.trail_verts[n - 1]
	pts[1] = body.display_pos - position
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, arrays)
