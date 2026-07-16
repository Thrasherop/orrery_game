class_name SolarSystemView
extends Node3D
## Owns all world visuals: sun view, body views, trails, velocity arrows,
## the starfield and impact effects. Reads SimBody state every frame and
## reacts to lifecycle/selection/toggle events.

var sim: Simulation
var textures: Dictionary = {}

var sun_view: SunView
var starfield: Starfield
var effects: ImpactEffects
var preview: AddPreview

var body_views := {}    # SimBody -> BodyView
var trail_views := {}   # SimBody -> TrailView
var arrows := {}        # SimBody -> VelocityArrow (customs only)


func setup(sim_: Simulation, textures_: Dictionary) -> void:
	sim = sim_
	textures = textures_

	starfield = Starfield.new()
	add_child(starfield)

	sun_view = SunView.new()
	sun_view.setup(sim.sun)
	add_child(sun_view)
	_add_trail(sim.sun)

	for b in sim.planets:
		_add_body_view(b)

	effects = ImpactEffects.new()
	add_child(effects)

	preview = AddPreview.new()
	add_child(preview)

	Events.body_added.connect(_on_body_added)
	Events.body_removed.connect(_on_body_removed)
	Events.merged.connect(_on_merged)
	Events.selection_changed.connect(_on_selection_changed)
	Events.orbits_toggled.connect(_on_orbits_toggled)
	Events.vectors_toggled.connect(_on_vectors_toggled)


func _add_body_view(b: SimBody) -> void:
	var v := BodyView.new()
	v.setup(b, textures)
	add_child(v)
	body_views[b] = v
	_add_trail(b)
	if b.custom:
		var arrow := VelocityArrow.new()
		arrow.setup(b.color)
		arrow.visible = Events.show_vectors
		add_child(arrow)
		arrows[b] = arrow


func _add_trail(b: SimBody) -> void:
	var t := TrailView.new()
	t.setup(b)
	t.visible = Events.show_orbits
	add_child(t)
	trail_views[b] = t


func _on_body_added(b: SimBody) -> void:
	_add_body_view(b)


func _on_body_removed(b: SimBody) -> void:
	if body_views.has(b):
		body_views[b].queue_free()
		body_views.erase(b)
	if trail_views.has(b):
		trail_views[b].queue_free()
		trail_views.erase(b)
	if arrows.has(b):
		arrows[b].queue_free()
		arrows.erase(b)


func _on_merged(_survivor: SimBody, _loser_name: String, impact_pos: Vector3, color: Color, effect_scale: float) -> void:
	effects.spawn(impact_pos, color, effect_scale)


func _on_selection_changed(_body) -> void:
	# selected trail pops brighter, like the prototype's select()
	for b in trail_views:
		if b.is_sun:
			continue
		var selected: bool = Events.selected == b
		if b.custom:
			trail_views[b].set_opacity(0.9 if selected else 0.5)
		else:
			trail_views[b].set_opacity(0.65 if selected else 0.24)


func _on_orbits_toggled(on: bool) -> void:
	for b in trail_views:
		trail_views[b].visible = on


func _on_vectors_toggled(on: bool) -> void:
	for b in arrows:
		arrows[b].visible = on


func update_world(dt: float, days: float, cam: Camera3D) -> void:
	sun_view.update_view(days, cam)
	for b in body_views:
		body_views[b].update_view(days, cam)
	for b in trail_views:
		trail_views[b].refresh()
	for b in arrows:
		var arrow: VelocityArrow = arrows[b]
		arrow.position = b.display_pos
		if b.vel_display.length_squared() > 1e-14:
			arrow.set_direction(b.vel_display)
		var alen := clampf(2.5 + b.vel_kms * 0.3, 2.5, 26.0)
		arrow.set_arrow_length(alen, alen * 0.22, alen * 0.13)
	starfield.update_rotation(dt)
	effects.update_effects(dt)
	preview.follow_sun(sim.sun.display_pos)


## pick candidates for the camera rig's ray caster
func pick_candidates() -> Array:
	var out: Array = []
	out.append({ body = sim.sun, pos = sim.sun.display_pos, radius = sim.sun.pick_radius() })
	for b in body_views:
		out.append({ body = b, pos = b.display_pos, radius = b.pick_radius() })
	return out
