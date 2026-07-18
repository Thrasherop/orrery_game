class_name TrailFrames
## The trail reference-frame system. Trails are stored on each SimBody as
## frame-independent samples — (sim_day, local, anchor) where `local` is the
## body's display offset from its anchor body (the sun, or a moon's host) at
## the sample time and `anchor` is that anchor's absolute display position at
## the sample time — and this class turns a sample into a mesh vertex for the
## active viewing frame. Because the raw samples never depend on the frame,
## switching modes just recomputes vertices: no reset, no history loss.
##
## Mesh vertices are LOCAL to the TrailView, which is positioned every frame
## at anchor_now(). The invariant every mode preserves: the newest sample's
## vertex + anchor_now == the body's current display position, so a trail
## always ends exactly at its body no matter how the display frame drifts
## (the bug that motivated this system: absolute-space trails got orphaned
## whenever a heavy newcomer dragged the sun/barycenter frame around).

enum { MODE_LOCAL, MODE_INERTIAL, MODE_GALAXY, MODE_FOCUS, MODE_TRUE }

const MODE_NAMES := ["Sun-locked", "True motion", "Galaxy", "Focus", "Real space"]

## Display-space drift of the whole solar system through the galaxy
## (galaxy mode only). Direction is tilted out of the ecliptic toward the
## solar apex-ish; magnitude is tuned for looks: ~66 display units per year,
## a bit over one Earth-orbit diameter — enough that orbits visibly stretch
## into helices without instantly streaming away.
const GAL_V := Vector3(0.10164, 0.11226, -0.08585)   # display units / sim-day
## Galaxy-mode trails are windowed to this many sim-days: an outer planet's
## full 2-orbit buffer (centuries) would otherwise stretch thousands of
## units across the scene.
const GAL_WINDOW_DAYS := 4000.0

static var mode: int = MODE_LOCAL
## Reference body for MODE_FOCUS (kept non-null by Simulation: the selected
## body, falling back to the sun).
static var focus: SimBody = null


## Vertex for a sample being pushed live. `focus_abs` is the focus body's
## absolute display position at the sample time — only read in MODE_FOCUS,
## and supplied by the caller because only the simulation knows the exact
## in-substep position (SimBody.display_pos can be a frame stale). `bary` is the
## body's raw barycentric offset in AU (position − barycenter) at the sample
## time — only read in MODE_TRUE, where it's compressed on its own so the trail
## shows the honest single-compression path with no sun-anchoring artifact.
static func vertex(day: float, local: Vector3, anchor: Vector3, focus_abs: Vector3, bary := Vector3.ZERO) -> Vector3:
	match mode:
		MODE_LOCAL:
			return local
		MODE_GALAXY:
			return anchor + local + GAL_V * day
		MODE_FOCUS:
			return anchor + local - focus_abs
		MODE_TRUE:
			return Units.to_display(bary) + GAL_V * day
		_:
			return anchor + local


## Vertex for a historical sample (mode-switch rebuild): MODE_FOCUS
## reconstructs the focus body's past position from its own trail history.
static func vertex_hist(day: float, local: Vector3, anchor: Vector3, bary := Vector3.ZERO) -> Vector3:
	if mode == MODE_FOCUS:
		return anchor + local - focus_abs_at(day)
	return vertex(day, local, anchor, Vector3.ZERO, bary)


## Where a body's TrailView sits this frame (mesh vertices are relative to it).
static func anchor_now(b: SimBody, sun: SimBody, now_day: float) -> Vector3:
	match mode:
		MODE_LOCAL:
			if b.is_moon and b.host != null:
				return b.host.display_pos
			return sun.display_pos
		MODE_GALAXY, MODE_TRUE:
			return -GAL_V * now_day
		MODE_FOCUS:
			return focus.display_pos if focus != null else sun.display_pos
		_:
			return Vector3.ZERO


## A frame can make a body's own trail degenerate (all zeros) — hide it.
static func trail_visible(b: SimBody) -> bool:
	if mode == MODE_LOCAL:
		return not b.is_sun
	if mode == MODE_FOCUS:
		return b != focus
	return true


## The focus body's absolute display position at `day`, interpolated from its
## own trail history (anchor + local == absolute by construction). Days
## outside the recorded span clamp to the nearest sample, so trails that
## reach further back than the focus body's history degrade to a rigid
## (true-motion) tail instead of garbage.
static func focus_abs_at(day: float) -> Vector3:
	var f := focus
	if f == null:
		return Vector3.ZERO
	var n := f.trail_days.size()
	if n == 0:
		return f.display_pos
	if day <= f.trail_days[0]:
		return f.trail_anchor[0] + f.trail_local[0]
	if day >= f.trail_days[n - 1]:
		return f.trail_anchor[n - 1] + f.trail_local[n - 1]
	var i := f.trail_days.bsearch(day)   # first index with days[i] >= day; 1..n-1 here
	var d0 := f.trail_days[i - 1]
	var d1 := f.trail_days[i]
	var t := 0.0 if d1 <= d0 else (day - d0) / (d1 - d0)
	var a := f.trail_anchor[i - 1] + f.trail_local[i - 1]
	var b := f.trail_anchor[i] + f.trail_local[i]
	return a.lerp(b, t)
