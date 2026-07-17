class_name NBodySystem
extends RefCounted
## Symplectic leapfrog N-body integrator (kick-drift-kick) over all mutual
## gravitational pairs. Pure numerics — knows nothing about rendering except
## that it maintains barycentric *display* positions (compressed) per part,
## because collisions in this game happen when the rendered meshes overlap.
##
## State is kept in PackedFloat64Arrays for double precision (Vector3 is
## 32-bit floats, not enough for a long-running integration).

const EPS2 := 1e-8                   # gravitational softening (AU²)

var bodies: Array = []               # SimBody refs, index-aligned with the arrays
var px := PackedFloat64Array()       # position, AU, scene axes
var py := PackedFloat64Array()
var pz := PackedFloat64Array()
var vx := PackedFloat64Array()       # velocity, AU/day
var vy := PackedFloat64Array()
var vz := PackedFloat64Array()
var ax := PackedFloat64Array()       # acceleration, AU/day²
var ay := PackedFloat64Array()
var az := PackedFloat64Array()
var m := PackedFloat64Array()        # solar masses
var base_m := PackedFloat64Array()   # 1× baseline for the mass slider

var disp := PackedVector3Array()     # barycentric display positions
var prev_disp := PackedVector3Array()

var tau_min := INF                   # dynamical timescale of the tightest pair
var bary_x := 0.0
var bary_y := 0.0
var bary_z := 0.0

# Injecting or removing a body changes the mass distribution, so the
# mass-weighted barycenter used below jumps even though every existing
# body's actual (px,py,pz) didn't move — without this, every body on
# screen would leap the instant a new one is added or removed. This
# accumulates the barycenter jump so already-visible bodies stay put;
# see absorb_frame_shift().
var frame_corr := Vector3.ZERO


func count() -> int:
	return bodies.size()


func add_body(body, mass: float) -> int:
	bodies.append(body)
	px.append(0.0); py.append(0.0); pz.append(0.0)
	vx.append(0.0); vy.append(0.0); vz.append(0.0)
	ax.append(0.0); ay.append(0.0); az.append(0.0)
	m.append(mass)
	base_m.append(mass)
	disp.append(Vector3.ZERO)
	prev_disp.append(Vector3.ZERO)
	return bodies.size() - 1


func remove_at(i: int) -> void:
	bodies.remove_at(i)
	px.remove_at(i); py.remove_at(i); pz.remove_at(i)
	vx.remove_at(i); vy.remove_at(i); vz.remove_at(i)
	ax.remove_at(i); ay.remove_at(i); az.remove_at(i)
	m.remove_at(i)
	base_m.remove_at(i)
	disp.remove_at(i)
	prev_disp.remove_at(i)


func index_of(body) -> int:
	return bodies.find(body)


## real (uncompressed) separation of two parts, AU
func real_distance(i: int, j: int) -> float:
	var dx := px[i] - px[j]
	var dy := py[i] - py[j]
	var dz := pz[i] - pz[j]
	return sqrt(dx * dx + dy * dy + dz * dz)


func barycenter() -> Vector3:
	var n := count()
	if n == 0:
		return Vector3.ZERO
	var bx := 0.0
	var by := 0.0
	var bz := 0.0
	var M := 0.0
	for i in n:
		bx += px[i] * m[i]
		by += py[i] * m[i]
		bz += pz[i] * m[i]
		M += m[i]
	return Vector3(bx / M, by / M, bz / M)


## Call right after a body is injected or removed (mass appearing/vanishing
## rather than being conserved, e.g. NOT a merge) with the barycenter from
## just before the change. Folds the resulting jump into frame_corr so
## already-visible bodies don't leap on the next refresh_display().
func absorb_frame_shift(bary_before: Vector3) -> void:
	frame_corr += barycenter() - bary_before


func compute_accel(g_scale: float) -> void:
	var n := count()
	var G := Units.GM_SUN * g_scale   # user-tunable gravitational constant
	var tau2min := INF
	for q in n:
		ax[q] = 0.0
		ay[q] = 0.0
		az[q] = 0.0
	for i in range(n):
		for j in range(i + 1, n):
			var dx := px[j] - px[i]
			var dy := py[j] - py[i]
			var dz := pz[j] - pz[i]
			var r2 := dx * dx + dy * dy + dz * dz + EPS2
			var r3 := r2 * sqrt(r2)
			var f := G / r3
			ax[i] += f * m[j] * dx
			ay[i] += f * m[j] * dy
			az[i] += f * m[j] * dz
			ax[j] -= f * m[i] * dx
			ay[j] -= f * m[i] * dy
			az[j] -= f * m[i] * dz
			# dynamical timescale of this pair: tau² = r³ / G(mA+mB).
			# The integrator shrinks its step to resolve the tightest pair.
			var t2 := r3 / (G * (m[i] + m[j]))
			if t2 < tau2min:
				tau2min = t2
	tau_min = sqrt(tau2min)


## Per-body dynamical timescale for the physics-load panel: for every part,
## the tau of its tightest pair — attributed to the LIGHTER member (putting
## that one on rails is what would relax the step). Same formula the adaptive
## substep uses; INF for bodies that don't constrain it.
func per_body_tau(g_scale: float) -> PackedFloat64Array:
	var n := count()
	var out := PackedFloat64Array()
	out.resize(n)
	out.fill(INF)
	var G := Units.GM_SUN * g_scale
	for i in range(n):
		for j in range(i + 1, n):
			var dx := px[j] - px[i]
			var dy := py[j] - py[i]
			var dz := pz[j] - pz[i]
			var r2 := dx * dx + dy * dy + dz * dz + EPS2
			var t := sqrt(r2 * sqrt(r2) / (G * (m[i] + m[j])))
			var k := j if m[j] <= m[i] else i
			if t < out[k]:
				out[k] = t
	return out


## One kick-drift-kick substep of h days.
func leapfrog_substep(h: float, g_scale: float) -> void:
	var n := count()
	var h2 := h / 2.0
	for i in n:
		vx[i] += ax[i] * h2
		vy[i] += ay[i] * h2
		vz[i] += az[i] * h2
		px[i] += vx[i] * h
		py[i] += vy[i] * h
		pz[i] += vz[i] * h
	compute_accel(g_scale)
	for i in n:
		vx[i] += ax[i] * h2
		vy[i] += ay[i] * h2
		vz[i] += az[i] * h2


## Mass-weighted center & display refresh. The underlying state is tracked in
## a BARYCENTRIC (inertial) frame so mutual gravity between e.g. two stars is
## never lost — but display positions are built sun-anchored: only the sun's
## own (barycentric) position is compressed against the barycenter, and every
## other body is compressed HELIOCENTRICALLY (relative to the sun) and then
## placed next to wherever the sun landed. This still shows the sun's real,
## fully inertial motion (nothing is ignored or fixed at the origin) — it's
## just computed as translation + local shape instead of one combined vector.
## That split matters because Units.to_display() is a nonlinear (r^0.62)
## compression: applying it once to (planet_pos - barycenter) compresses the
## radial and tangential components of that vector by different factors
## whenever the vector is large, so once a distant heavy companion drags the
## barycenter far from the sun, the whole sun+planets cluster shares one huge
## near-identical offset and gets warped like a fisheye lens (orbits pinch
## into flat/W shapes near the old sun position). Compressing the sun's own
## offset and each planet's small, always-well-behaved heliocentric offset
## separately keeps the local system's shape intact regardless of how far
## away — or how heavy — a companion body drags the barycenter.
## reset_prev=true also snaps prev_disp (used on seed/inject);
## reset_prev=false records prev_disp first (per-substep, drives collisions).
func refresh_display(reset_prev: bool) -> void:
	var n := count()
	var b := barycenter()
	bary_x = b.x
	bary_y = b.y
	bary_z = b.z
	var sun_disp := Vector3.ZERO
	if n > 0:
		sun_disp = Units.to_display(Vector3(px[0] - bary_x, py[0] - bary_y, pz[0] - bary_z) + frame_corr)
	for i in n:
		if not reset_prev:
			prev_disp[i] = disp[i]
		if i == 0:
			disp[i] = sun_disp
		else:
			disp[i] = sun_disp + Units.to_display(Vector3(px[i] - px[0], py[i] - py[0], pz[i] - pz[0]))
		if reset_prev:
			prev_disp[i] = disp[i]


## remove net momentum so the barycenter stays put (a pure Galilean shift)
func zero_momentum() -> void:
	var n := count()
	var mx := 0.0
	var my := 0.0
	var mz := 0.0
	var M := 0.0
	for i in n:
		mx += vx[i] * m[i]
		my += vy[i] * m[i]
		mz += vz[i] * m[i]
		M += m[i]
	mx /= M
	my /= M
	mz /= M
	for i in n:
		vx[i] -= mx
		vy[i] -= my
		vz[i] -= mz


## minimum separation of two parts across the last substep, assuming linear
## relative motion in display space
func swept_distance(i: int, j: int) -> float:
	var p0 := prev_disp[i] - prev_disp[j]
	var u := (disp[i] - disp[j]) - p0
	var uu := u.dot(u)
	var t := 0.0
	if uu > 1e-12:
		t = -p0.dot(u) / uu
	t = clampf(t, 0.0, 1.0)
	return (p0 + u * t).length()


## perfectly inelastic merger of the raw state: conserve momentum, sum masses.
## Survivor/loser choice and all visual consequences live in the sim layer.
func merge_parts(si: int, li: int) -> void:
	var mm := m[si] + m[li]
	var ws := m[si] / mm
	var wl := m[li] / mm
	px[si] = px[si] * ws + px[li] * wl
	py[si] = py[si] * ws + py[li] * wl
	pz[si] = pz[si] * ws + pz[li] * wl
	vx[si] = vx[si] * ws + vx[li] * wl
	vy[si] = vy[si] * ws + vy[li] * wl
	vz[si] = vz[si] * ws + vz[li] * wl
	m[si] = mm
	base_m[si] = mm        # merged mass becomes the new 1× baseline


## user inputs → sun-relative state vector (doubles). Direction 0° = prograde
## (counterclockwise, like the planets), +90° = radially outward.
## Latitude lifts the launch point out of the ecliptic; the prograde
## direction stays horizontal, so the resulting orbit is inclined.
## cfg: { dist_au, lon_deg, lat_deg, speed_kms, dir_deg }
static func state_vector_from_inputs(cfg: Dictionary) -> Dictionary:
	var th: float = cfg.lon_deg * Units.DEG
	var ph: float = cfg.get("lat_deg", 0.0) * Units.DEG
	var dl: float = cfg.dir_deg * Units.DEG
	var radial := [cos(ph) * cos(th), sin(ph), -cos(ph) * sin(th)]
	var prograde := [-sin(th), 0.0, -cos(th)]   # still ⟂ radial
	var p := [radial[0] * cfg.dist_au, radial[1] * cfg.dist_au, radial[2] * cfg.dist_au]
	var s: float = cfg.speed_kms / Units.KMS_PER_AUDAY
	var cd := cos(dl)
	var sd := sin(dl)
	var v := [
		(prograde[0] * cd + radial[0] * sd) * s,
		(prograde[1] * cd + radial[1] * sd) * s,
		(prograde[2] * cd + radial[2] * sd) * s,
	]
	return { p = p, v = v }
