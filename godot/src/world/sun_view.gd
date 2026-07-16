class_name SunView
extends Node3D
## The sun: bright sphere + two additive glow billboards. The outer halo's
## opacity eases down as the camera pulls back so it never washes the screen.

const GLOW_SHADER := preload("res://src/gfx/glow_billboard.gdshader")

var body: SimBody
var mesh_inst: MeshInstance3D
var halo_mat: ShaderMaterial
var glow_sprite: MeshInstance3D
var halo_sprite: MeshInstance3D


func setup(sun_body: SimBody) -> void:
	body = sun_body
	name = "Sun"

	var sphere := SphereMesh.new()
	sphere.radius = body.size
	sphere.height = body.size * 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# HDR-bright so the glow pass blooms the disc like UnrealBloomPass did
	mat.albedo_color = Color(1.0 * 2.2, 0.875 * 2.2, 0.62 * 2.2)
	mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = sphere
	mesh_inst.material_override = mat
	add_child(mesh_inst)

	var glow_mat := make_glow_material(GLOW_SHADER,
		TextureFactory.make_glow(Color(1, 235 / 255.0, 190 / 255.0, 1), Color(1, 150 / 255.0, 50 / 255.0, 0.35)),
		Color.WHITE, 1.0)
	glow_sprite = make_glow_sprite(glow_mat, 46.0)
	add_child(glow_sprite)

	halo_mat = make_glow_material(GLOW_SHADER,
		TextureFactory.make_glow(Color(1, 200 / 255.0, 120 / 255.0, 0.5), Color(1, 120 / 255.0, 40 / 255.0, 0.12)),
		Color.WHITE, 0.55)
	halo_sprite = make_glow_sprite(halo_mat, 110.0)
	add_child(halo_sprite)


static func make_glow_material(shader: Shader, tex: Texture2D, tint: Color, opacity: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("glow_tex", tex)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("opacity", opacity)
	return mat


static func make_glow_sprite(mat: ShaderMaterial, sprite_scale: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.scale = Vector3.ONE * sprite_scale
	# billboard handled in the shader; cull margin so it survives frustum tests
	mi.extra_cull_margin = sprite_scale
	return mi


func update_view(days: float, cam: Camera3D) -> void:
	position = body.display_pos
	mesh_inst.rotation.y = (days * 24.0 / body.day_hours) * TAU
	# keep sun glow steady regardless of zoom
	halo_mat.set_shader_parameter("opacity", clampf(0.65 - cam.global_position.length() / 2500.0, 0.15, 0.65))
	# three.js clips sprites whose center is behind the camera; Godot
	# billboards keep covering the screen — replicate the clip or the huge
	# halo washes everything out when the sun slips behind the view
	var behind := cam.is_position_behind(global_position)
	glow_sprite.visible = not behind
	halo_sprite.visible = not behind
