extends Node
## Global event bus (autoload "Events").
## Cross-layer notifications + a little shared UI state (selection, display toggles).

# selection --------------------------------------------------------------
signal select_requested(body)      # SimBody — anyone may ask for a selection
signal deselect_requested()
signal selection_changed(body)     # SimBody or null — authoritative, emitted by main

var selected = null                # SimBody or null (kept in sync by main)

# body lifecycle ---------------------------------------------------------
signal body_added(body)            # SimBody (custom bodies)
signal body_removed(body)          # SimBody (custom removal or merged-away planet)
signal bodies_changed()            # rail/labels should rebuild

# simulation events ------------------------------------------------------
signal mode_changed()              # Kepler <-> N-body, or G scale changed
signal moons_mode_changed()        # simulate-moons flags flipped (Kepler mode only)
signal merged(survivor, loser_name, impact_pos, color, effect_scale)
signal toast_requested(msg)

# display toggles (owned here so world + UI both see them) ---------------
signal orbits_toggled(on)
signal labels_toggled(on)
signal vectors_toggled(on)
signal trail_mode_changed(mode)    # authoritative state lives in TrailFrames.mode
signal real_scale_changed(on)      # authoritative state lives in Units.real_scale

var show_orbits := true
var show_labels := true
var show_vectors := true


func _ready() -> void:
	TrailFrames.mode = Prefs.trail_mode()
	Units.real_scale = Prefs.real_scale()

# add-body panel live preview --------------------------------------------
signal add_preview_changed(cfg)    # Dictionary of inputs, or null to hide


func set_show_orbits(on: bool) -> void:
	show_orbits = on
	orbits_toggled.emit(on)


func set_show_labels(on: bool) -> void:
	show_labels = on
	labels_toggled.emit(on)


func set_show_vectors(on: bool) -> void:
	show_vectors = on
	vectors_toggled.emit(on)


func set_trail_mode(m: int) -> void:
	if TrailFrames.mode == m:
		return
	TrailFrames.mode = m
	Prefs.set_trail_mode(m)
	trail_mode_changed.emit(m)


func set_real_scale(on: bool) -> void:
	if Units.real_scale == on:
		return
	Units.real_scale = on
	Prefs.set_real_scale(on)
	real_scale_changed.emit(on)
