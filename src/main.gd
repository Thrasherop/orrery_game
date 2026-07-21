extends Node3D
## Application root: builds the environment, generates procedural textures,
## constructs the simulation, world views, camera rig and HUD, and drives the
## per-frame update in a deterministic order (sim → world → camera → HUD).

const VIGNETTE_SHADER := preload("res://src/gfx/vignette.gdshader")

var sim: Simulation
var world: SolarSystemView
var camera_rig: CameraRig
var hud   # Hud (desktop/web) or MobileHud (touch handhelds) — same update API
var labels: LabelsLayer
var _booted := false


func _ready() -> void:
	_setup_environment()
	_setup_vignette()

	sim = Simulation.new()
	add_child(sim)

	# procedural textures must exist before the views are built
	var factory := TextureFactory.new()
	add_child(factory)
	await factory.generate(Catalog.make_planets())

	world = SolarSystemView.new()
	add_child(world)
	world.setup(sim, factory.textures)

	camera_rig = CameraRig.new()
	add_child(camera_rig)
	camera_rig.pick_provider = world.pick_candidates

	# full-screen input surface (default canvas, under every HUD CanvasLayer):
	# the GUI routes pointer/touch events here only when no panel claims them,
	# so camera gestures and UI interaction never fight over a touch
	var gestures := Control.new()
	gestures.name = "GestureSurface"
	gestures.set_anchors_preset(Control.PRESET_FULL_RECT)
	gestures.gui_input.connect(camera_rig.handle_gui_input)
	add_child(gestures)

	labels = LabelsLayer.new()
	add_child(labels)
	labels.setup(sim, camera_rig)

	# phones get a bottom-sheet paradigm; desktop keeps the edge-drawer layout
	hud = MobileHud.new() if UX.handheld else Hud.new()
	add_child(hud)
	hud.setup(sim, camera_rig)

	Events.select_requested.connect(_on_select_requested)
	Events.deselect_requested.connect(_deselect)
	Events.body_removed.connect(_on_body_removed)
	Events.add_preview_changed.connect(_on_add_preview_changed)

	_booted = true
	print("[orrery] boot complete — %d textures, %d bodies" % [factory.textures.size(), sim.all_bodies().size()])


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("05070d")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("334466")
	# three.js physical lights divide by π — 0.35 in the prototype ≈ 0.11 here
	env.ambient_light_energy = 0.12
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	# UnrealBloomPass(strength 0.75, radius 0.55, threshold 0.62) equivalent —
	# threshold sits just above lit-surface level so planets stay crisp while
	# the sun and glow sprites (emissive, > 1.0) bloom
	env.glow_enabled = true
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 1.0
	env.glow_intensity = 0.55
	env.glow_strength = 1.0
	env.glow_bloom = 0.05
	if OS.has_feature("web"):
		# the Compatibility renderer's glow doesn't do proper HDR threshold
		# extraction — it washes the whole frame blue instead of blooming
		# just the bright sun/planet discs (raising glow_hdr_threshold has
		# no effect, confirming it isn't reading real HDR values here).
		# The sun/planet halos are already self-contained additive billboard
		# sprites (sun_view.gd), so losing this extra bloom layer on web
		# costs little.
		env.glow_enabled = false
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# the sun light: constant (no falloff), warm white — three.js
	# PointLight(0xfff2dd, 2.6, distance 0, decay 0); physical lights are
	# divided by π there, so ≈ 0.85 in Godot's units
	var light := OmniLight3D.new()
	light.light_color = Color("fff2dd")
	light.light_energy = 0.9
	light.light_specular = 0.2
	light.omni_range = 3000.0
	light.omni_attenuation = 0.0
	light.shadow_enabled = false
	light.name = "SunLight"
	add_child(light)


func _setup_vignette() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = VIGNETTE_SHADER
	rect.material = mat
	layer.add_child(rect)
	add_child(layer)


func _process(delta: float) -> void:
	if not _booted:
		return
	var dt := minf(delta, 0.05)

	sim.tick(dt)
	var days := SimTime.sim_days(sim.sim_ms)

	# the sun light tracks the (possibly wobbling) sun
	($SunLight as OmniLight3D).position = sim.sun.display_pos

	world.update_world(dt, days, camera_rig.cam)
	camera_rig.update_camera(dt)
	hud.update_live()
	labels.update_labels()


func _on_select_requested(body) -> void:
	var reselect: bool = Events.selected == body
	Events.selected = body
	Events.selection_changed.emit(body)
	# animate camera to frame the body (not when merely refreshing the card)
	if not reselect:
		camera_rig.fly_to(body)


func _deselect() -> void:
	Events.selected = null
	Events.selection_changed.emit(null)


func _on_body_removed(body) -> void:
	if Events.selected == body:
		_deselect()


## add-body panel opened/edited/closed: frame the proposed body while the
## panel is open (fly there once, then update_camera tracks it live)
func _on_add_preview_changed(cfg) -> void:
	if cfg == null:
		camera_rig.end_preview_focus()
	elif not camera_rig.preview_focus_active():
		camera_rig.focus_preview(world.preview.focus_position, world.preview.focus_size())
