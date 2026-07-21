extends Node3D
## Diagnostic probe: which camera near/far combos break rendering. Replicates
## main's environment (glow+ACES, omni light) with a true-scale sphere at
## Earth's real-scale world position and a distant star shell, then sweeps
## near/far and saves probe_*.png. Finding (2026-07): the scene goes fully
## black (light culler prepare_camera errors) past a near/far ratio of ~1e7;
## 9e6 renders fine — CameraRig._update_near caps the ratio at 5e6.
##   godot --path godot res://tests/near_probe.tscn


func _ready() -> void:
	get_window().size = Vector2i(800, 450)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("05070d")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("334466")
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_intensity = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var light := OmniLight3D.new()
	light.light_color = Color("fff2dd")
	light.light_energy = 0.9
	light.omni_range = 3000.0
	light.omni_attenuation = 0.0
	add_child(light)

	var stars := Starfield.new()
	add_child(stars)

	# Earth-sized sphere at Earth's real-scale world position (7 units out)
	var r := 6371.0 / Units.AU_KM * Units.REAL_AU
	var center := Vector3(7, 0, 0)
	var sphere := SphereMesh.new()
	sphere.radius = r
	sphere.height = r * 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.6, 0.9)
	mat.roughness = 0.9
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = mat
	mi.position = center
	add_child(mi)

	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.far = 9000.0
	add_child(cam)
	cam.position = center + Vector3(0, 0, r * 3.0)
	cam.look_at(center, Vector3.UP)

	var cases := [
		[0.1, 9000.0], [0.01, 9000.0], [0.001, 9000.0],
		[0.0001, 9000.0], [0.00002, 9000.0],
		[0.0001, 900.0], [0.0001, 90.0], [0.00002, 20.0],
	]
	await get_tree().process_frame
	for c in cases:
		cam.near = c[0]
		cam.far = c[1]
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "res://tests/probe_n%s_f%s.png" % [str(c[0]).replace(".", "p"), str(int(c[1]))]
		img.save_png(path)
		print("[probe] near=%s far=%s -> %s" % [c[0], c[1], path])
	get_tree().quit(0)
