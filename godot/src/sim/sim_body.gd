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

# live per-frame outputs from the simulation
var r_au := 0.0             # sun-relative distance
var vel_kms := 0.0          # sun-relative speed
var display_pos := Vector3.ZERO
var vel_display := Vector3.ZERO   # raw velocity (scene axes) — drives custom arrows

# realtime orbit trail — ring buffer of display-space points
var trail_points := PackedVector3Array()
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


func trail_push(pos: Vector3) -> void:
	if trail_points.size() >= trail_max:
		trail_points.remove_at(0)
	trail_points.append(pos)
	trail_version += 1


func trail_clear() -> void:
	trail_points.clear()
	trail_next_day = -INF
	trail_lv_ok = false
	trail_version += 1


## radius of the invisible pick sphere (bigger than the body, easier to click)
func pick_radius() -> float:
	if is_sun:
		return size * 1.4
	return maxf(size * 2.2, 1.8)
