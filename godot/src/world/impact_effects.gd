class_name ImpactEffects
extends Node3D
## Impact flash (expanding additive billboard) + debris (manually-advanced
## point cloud), ported from the prototype's spawnImpact/updateEffects.

const STAR_SHADER := preload("res://src/gfx/star_points.gdshader")

var _effects: Array = []
var _flash_tex: Texture2D = null


func spawn(disp_pos: Vector3, color: Color, effect_scale: float) -> void:
	if _flash_tex == null:
		_flash_tex = TextureFactory.make_glow(Color(1, 1, 1, 1), Color(1, 190 / 255.0, 110 / 255.0, 0.45))

	var fmat := SunView.make_glow_material(
		preload("res://src/gfx/glow_billboard.gdshader"),
		_flash_tex, Color("fff0d8"), 0.95)
	var flash := SunView.make_glow_sprite(fmat, effect_scale)
	flash.position = disp_pos
	add_child(flash)

	var N := 90
	var pos := PackedVector3Array()
	var vel := PackedVector3Array()
	var col := PackedColorArray()
	pos.resize(N)
	vel.resize(N)
	col.resize(N)
	var w := Color(1, 242 / 255.0, 221 / 255.0)
	for i in N:
		pos[i] = disp_pos
		var th := randf() * TAU
		var ph := acos(randf() * 2.0 - 1.0)
		var sp := (1.5 + randf() * 8.0) * effect_scale * 0.9
		vel[i] = Vector3(sin(ph) * cos(th), cos(ph), sin(ph) * sin(th)) * sp
		col[i] = color.lerp(w, randf() * 0.7)

	var dmat := ShaderMaterial.new()
	dmat.shader = STAR_SHADER
	dmat.set_shader_parameter("size_px", 0.4 * effect_scale)
	dmat.set_shader_parameter("opacity", 0.85)
	var debris := MeshInstance3D.new()
	debris.mesh = ArrayMesh.new()
	debris.material_override = dmat
	debris.custom_aabb = AABB(Vector3(-2000, -2000, -2000), Vector3(4000, 4000, 4000))
	add_child(debris)

	var e := {
		flash = flash, flash_mat = fmat, debris = debris, debris_mat = dmat,
		pos = pos, vel = vel, col = col, t = 0.0, dur = 1.6, scale = effect_scale,
	}
	_rebuild_debris(e)
	_effects.append(e)


func update_effects(dt: float) -> void:
	for i in range(_effects.size() - 1, -1, -1):
		var e: Dictionary = _effects[i]
		e.t += dt
		var k: float = e.t / e.dur
		if k >= 1.0:
			e.flash.queue_free()
			e.debris.queue_free()
			_effects.remove_at(i)
			continue
		var fm: ShaderMaterial = e.flash_mat
		fm.set_shader_parameter("opacity", (1.0 - k) * 0.95)
		var flash: MeshInstance3D = e.flash
		flash.scale = Vector3.ONE * (e.scale * (1.0 + k * 9.0))
		var pos: PackedVector3Array = e.pos
		var vel: PackedVector3Array = e.vel
		for j in pos.size():
			pos[j] += vel[j] * dt
		e.pos = pos
		var dm: ShaderMaterial = e.debris_mat
		dm.set_shader_parameter("opacity", (1.0 - k) * 0.85)
		_rebuild_debris(e)


func _rebuild_debris(e: Dictionary) -> void:
	var am: ArrayMesh = e.debris.mesh
	am.clear_surfaces()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = e.pos
	arrays[Mesh.ARRAY_COLOR] = e.col
	am.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
