class_name SimBody
extends RefCounted
## Runtime state for one celestial body (sun, planet or custom). Created from
## a BodyDef (planets/sun) or from add-body inputs (customs). Views and UI read
## from this; Simulation writes to it.

var body_name := ""
var color := Color.WHITE
var body_type := ""
var desc := ""
var is_sun := false
var custom := false
var is_star := false        # custom body massive enough to shine (>= 20,000 M⊕)

var mass_e := 0.0           # custom bodies: Earth masses (shown in the info card)
var size := 1.0             # display radius (grows on merger)
var tilt := 0.0
var day_hours := 24.0
var radius_km := 0.0
var period_days := 0.0      # 0 = none
var el := {}                # Keplerian elements (planets only)
var tex := {}               # procedural texture cfg / custom palette index
var moons: Array = []
var has_rings := false

var mass_scale := 1.0       # info-card mass slider multiplier

# Per-body simulation toggle (info-card checkbox; moons and customs only).
# false = "on rails": the body glides on a circular orbit frozen from its
# state at disable time — it exerts no gravity, feels none, can't collide,
# and costs the integrator nothing. New bodies are always simulated.
var simulated := true
var rail_u := Vector3.ZERO  # unit radial direction at the freeze moment
var rail_w := Vector3.ZERO  # unit tangential (motion) direction at freeze
var rail_a := 0.0           # circle radius, AU (anchor-relative)
var rail_omega := 0.0       # angular rate, rad/day
var rail_day0 := 0.0        # sim-day of the freeze (phase zero)

# simulated moons (is_moon). Real physics runs at a_au scale; on screen the
# host-relative offset is amplified by disp_k so the moon renders at the
# catalog's exaggerated distance. host is the CURRENT gravitational primary
# (Hill-sphere binding, may change when a moon is stolen); null = free body
# on the standard heliocentric display mapping.
var is_moon := false
var host: SimBody = null
var host_prev: SimBody = null     # previous regime, kept while the display blends
var home_host_name := ""          # original planet (texture key / snapshot / grouping)
var a_au := 0.0                   # initial semi-major axis (circular), AU
var incl_deg := 0.0
var phase0 := 0.0                 # initial phase angle (matches decorative pivots)
var orbit_sign := 1.0             # -1 = retrograde (Triton)
var mass_solar := 0.0
var disp_k := 1.0                 # host-relative display amplification while bound
var catalog_disp_k := 0.0         # dist/a_au — restored when re-captured by home host
var disp_k_prev := 1.0
var bind_t := 1.0                 # 0→1 display blend after a host change

# cached row in NBodySystem's packed arrays while simulated (−1 = not in the
# integrator). Lets NBodySystem.index_of() skip its linear scan; kept correct
# by add_body/remove_at, self-heals if it ever goes stale.
var nb_index := -1

# live per-frame outputs from the simulation
var r_au := 0.0             # sun-relative distance
var vel_kms := 0.0          # sun-relative speed
var pos_au := Vector3.ZERO  # real heliocentric position (both modes)
var display_pos := Vector3.ZERO
var vel_display := Vector3.ZERO   # raw velocity (scene axes) — drives custom arrows

# realtime orbit trail — ring buffer of frame-independent samples (see
# TrailFrames): sim-day, display offset from the anchor body at sample time,
# and the anchor's absolute display position at sample time. trail_verts is
# the cached mesh geometry for the ACTIVE frame mode, appended in lockstep
# and rebuilt wholesale by trail_rebuild() when the mode/focus changes.
var trail_days := PackedFloat64Array()
var trail_local := PackedVector3Array()
var trail_anchor := PackedVector3Array()
var trail_verts := PackedVector3Array()
var trail_max := 0
var trail_next_day := -INF
var trail_interval := 1.0
var trail_lv := Vector3.ZERO      # unit velocity at last sample
var trail_lv_ok := false
var trail_version := 0            # bumped on every change; views rebuild on mismatch
var trail_opacity := 0.24         # base (unselected) opacity


static func from_def(def: BodyDef) -> SimBody:
	var b := SimBody.new()
	b.body_name = def.body_name
	b.color = def.color
	b.body_type = def.body_type
	b.desc = def.desc
	b.size = def.size
	b.tilt = def.tilt
	b.day_hours = def.day_hours
	b.radius_km = def.radius_km
	b.period_days = def.period_days
	b.el = def.el
	b.tex = def.tex
	b.moons = def.moons
	b.has_rings = def.has_rings
	return b


func init_trail(max_pts: int, opacity: float) -> void:
	trail_max = max_pts
	trail_opacity = opacity
	trail_clear()


## append one sample. `focus_abs` is only meaningful in MODE_FOCUS (the focus
## body's absolute display position at `day`) — pass ZERO otherwise.
func trail_push(day: float, local: Vector3, anchor: Vector3, focus_abs := Vector3.ZERO) -> void:
	if trail_days.size() >= trail_max:
		trail_days.remove_at(0)
		trail_local.remove_at(0)
		trail_anchor.remove_at(0)
		trail_verts.remove_at(0)
	trail_days.append(day)
	trail_local.append(local)
	trail_anchor.append(anchor)
	trail_verts.append(TrailFrames.vertex(day, local, anchor, focus_abs))
	trail_version += 1


func trail_size() -> int:
	return trail_days.size()


## recompute the cached vertices for the current TrailFrames mode/focus —
## the raw samples are frame-independent, so nothing is lost on a switch
func trail_rebuild() -> void:
	var n := trail_days.size()
	for i in n:
		trail_verts[i] = TrailFrames.vertex_hist(trail_days[i], trail_local[i], trail_anchor[i])
	trail_version += 1


func trail_clear() -> void:
	trail_days.clear()
	trail_local.clear()
	trail_anchor.clear()
	trail_verts.clear()
	trail_next_day = -INF
	trail_lv_ok = false
	trail_version += 1


## radius of the invisible pick sphere (bigger than the body, easier to click)
func pick_radius() -> float:
	if is_sun:
		return size * 1.4
	if is_moon:
		# the usual 1.8 floor would swallow the host planet next door
		return maxf(size * 2.2, 0.9)
	return maxf(size * 2.2, 1.8)
