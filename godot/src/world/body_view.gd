class_name BodyView
extends Node3D
## Visual node for a planet or custom body: tilted textured sphere, optional
## Saturn rings (radial-UV annulus), moons on inclined circular pivots, and
## for massive custom bodies a star glow. Spin/moon motion are decorative and
## driven from sim-days each frame, exactly like the prototype.

var body: SimBody
var axis: Node3D                 # axial tilt carrier
var mesh_inst: MeshInstance3D
var moon_views: Array = []       # { mesh: MeshInstance3D, dist, period, phase }
var star_glow: MeshInstance3D = null
var _base_size := 1.0            # display radius the mesh was built with


## decorative_moon_names: which of b.moons to render as kinematic pivots —
## null = all (legacy decorative mode), [] = none (they're simulated bodies
## with views of their own), or a subset (expensive moons excluded from the sim)
func setup(b: SimBody, textures: Dictionary, decorative_moon_names = null) -> void:
	body = b
	name = b.body_name
	_base_size = b.size

	var sphere := SphereMesh.new()
	sphere.radius = b.size
	sphere.height = b.size * 2.0
	sphere.radial_segments = 48
	sphere.rings = 24

	var mat: StandardMaterial3D
	if b.is_star:
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# HDR-bright so custom stars bloom like the sun
		mat.albedo_color = Color(1.0 * 2.2, 0.85 * 2.2, 0.63 * 2.2)
	else:
		mat = StandardMaterial3D.new()
		mat.roughness = 0.92
		mat.metallic = 0.0
		var tex_key: String = b.body_name
		if b.custom:
			tex_key = "custom%d" % b.tex.get("palette_index", 0)
		elif b.is_moon:
			tex_key = "moon:%s:%s" % [b.home_host_name, b.body_name]
		if textures.has(tex_key):
			mat.albedo_texture = textures[tex_key]
		else:
			mat.albedo_color = b.color

	mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = sphere
	mesh_inst.material_override = mat

	axis = Node3D.new()
	axis.rotation.z = -b.tilt * Units.DEG
	axis.add_child(mesh_inst)
	add_child(axis)

	if b.has_rings:
		axis.add_child(_make_rings(textures))

	if b.is_star:
		star_glow = _star_glow(b.size)
		add_child(star_glow)

	for idx in b.moons.size():
		var md: Dictionary = b.moons[idx]
		if decorative_moon_names != null and not (md.name in decorative_moon_names):
			continue   # this moon is simulated — it has a BodyView of its own
		var pivot := Node3D.new()
		pivot.rotation.z = md.get("incl", 3.0) * Units.DEG
		var moon_size: float = md["size"]   # ["size"] — dot access hits Dictionary.size()
		var msphere := SphereMesh.new()
		msphere.radius = moon_size
		msphere.height = moon_size * 2.0
		msphere.radial_segments = 20
		msphere.rings = 10
		var mmat := StandardMaterial3D.new()
		mmat.roughness = 0.95
		var mkey := "moon:%s:%s" % [b.body_name, md.name]
		if textures.has(mkey):
			mmat.albedo_texture = textures[mkey]
		else:
			mmat.albedo_color = Color(md.color)
		var mmesh := MeshInstance3D.new()
		mmesh.mesh = msphere
		mmesh.material_override = mmat
		pivot.add_child(mmesh)
		add_child(pivot)
		moon_views.append({ mesh = mmesh, dist = md.dist, period = md.period, phase = idx * 2.39996 })


func _make_rings(textures: Dictionary) -> MeshInstance3D:
	var inner: float = body.size * 1.35
	var outer: float = body.size * 2.35
	var segs := 128
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	for k in segs + 1:
		var a := TAU * float(k) / float(segs)
		var cx := cos(a)
		var sz := sin(a)
		verts.append(Vector3(cx * inner, 0, sz * inner))
		uvs.append(Vector2(0, 0.5))   # u follows radius (texture is a radial strip)
		normals.append(Vector3.UP)
		verts.append(Vector3(cx * outer, 0, sz * outer))
		uvs.append(Vector2(1, 0.5))
		normals.append(Vector3.UP)
	for k in segs:
		var base := k * 2
		idx.append_array([base, base + 2, base + 1, base + 1, base + 2, base + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = textures.get("ring")
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = mat
	return mi


func _star_glow(size: float) -> MeshInstance3D:
	var mat := SunView.make_glow_material(
		preload("res://src/gfx/glow_billboard.gdshader"),
		TextureFactory.make_glow(Color(1, 220 / 255.0, 170 / 255.0, 1), Color(1, 140 / 255.0, 60 / 255.0, 0.3)),
		Color.WHITE, 1.0)
	return SunView.make_glow_sprite(mat, size * 8.0)


func update_view(days: float, cam: Camera3D) -> void:
	position = body.display_pos
	# merged bodies grow: keep the mesh in sync with the sim's size
	if body.size != _base_size:
		mesh_inst.scale = Vector3.ONE * (body.size / _base_size)
	if star_glow != null:
		# sprite-clip like three.js (see sun_view)
		star_glow.visible = not cam.is_position_behind(global_position)
	# axial spin (negative day = retrograde)
	mesh_inst.rotation.y = (days * 24.0 / body.day_hours) * TAU
	for mv in moon_views:
		var ang: float = (days / mv.period) * TAU + mv.phase   # negative period = retrograde
		var mm: MeshInstance3D = mv.mesh
		mm.position = Vector3(cos(ang) * mv.dist, 0, -sin(ang) * mv.dist)
		mm.rotation.y = ang   # tidally locked
