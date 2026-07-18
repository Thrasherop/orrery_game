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
const MASS_COMPARABLE := 0.01        # mass ratio above which BOTH pair members subcycle
const SAFETY := 20.0                 # substeps per pair dynamical time (the tau/20 rule)
const K_MAX := 8                     # deepest subcycle rung (power of 2)

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

# Per-body dynamical timescale of the tightest pair each body participates in,
# refreshed by compute_accel. Attributed to the LIGHTER member (whose motion
# the pair force actually bends — putting it on rails / subcycling it relaxes
# the step), and to BOTH members when their masses are comparable. Drives the
# block integrator's rung assignment and the physics-load panel.
var tau_body := PackedFloat64Array()
var tau_min := INF                   # dynamical timescale of the tightest pair

# Block-integrator scratch (see step_block). k_sub is each body's rung (1/2/4/8)
# for the current block; enc_min_r2 is the n×n flat table of the min pair
# separation² sampled during a block's subcycles (anti-tunneling data for the
# collision scan); had_fast records whether the last block subcycled (so
# enc_min_r2 is meaningful). _f_a* is _accel_on's output, kept as members to
# avoid per-call allocation.
var k_sub := PackedInt32Array()
var enc_min_r2 := PackedFloat64Array()
var had_fast := false
var last_fast_evals := 0             # interior j-interactions in the last block (budget)
var _f_ax := 0.0
var _f_ay := 0.0
var _f_az := 0.0
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
	var idx := bodies.size()
	bodies.append(body)
	px.append(0.0); py.append(0.0); pz.append(0.0)
	vx.append(0.0); vy.append(0.0); vz.append(0.0)
	ax.append(0.0); ay.append(0.0); az.append(0.0)
	m.append(mass)
	base_m.append(mass)
	disp.append(Vector3.ZERO)
	prev_disp.append(Vector3.ZERO)
	tau_body.append(INF)
	body.nb_index = idx
	return idx


func remove_at(i: int) -> void:
	bodies[i].nb_index = -1
	bodies.remove_at(i)
	px.remove_at(i); py.remove_at(i); pz.remove_at(i)
	vx.remove_at(i); vy.remove_at(i); vz.remove_at(i)
	ax.remove_at(i); ay.remove_at(i); az.remove_at(i)
	m.remove_at(i)
	base_m.remove_at(i)
	disp.remove_at(i)
	prev_disp.remove_at(i)
	tau_body.remove_at(i)
	# every body after the hole shifted down one row
	for k in range(i, bodies.size()):
		bodies[k].nb_index = k


## O(1) via the body's cached row, falling back to a scan if it's ever stale
## (e.g. a body that was never added). Self-heals: the guard rejects a wrong
## cache and the caller keeps a valid index.
func index_of(body) -> int:
	var i: int = body.nb_index
	if i >= 0 and i < bodies.size() and bodies[i] == body:
		return i
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


## Body i's raw barycentric offset in AU (position − barycenter), frame-corrected
## so injection/removal doesn't make it jump — the honest "spatial coordinates"
## used by the Real-space (MODE_TRUE) path frame. Independent of the sun-anchored
## disp[]; pass a barycenter precomputed once per frame. The sun (i=0) returns
## exactly what refresh_display() compresses into disp[0], so it renders
## identically in both frames.
func bary_offset_au(i: int, bary: Vector3) -> Vector3:
	return Vector3(px[i] - bary.x, py[i] - bary.y, pz[i] - bary.z) + frame_corr


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
	if tau_body.size() != n:
		tau_body.resize(n)
	for q in n:
		ax[q] = 0.0
		ay[q] = 0.0
		az[q] = 0.0
		tau_body[q] = INF   # holds tau² until the sqrt pass at the end
	for i in range(n):
		# Hoist body i's row into locals and accumulate its acceleration in
		# locals too: packed-array indexing carries a bounds-check + dispatch
		# cost per access in GDScript, so pulling the O(n) inner loop off the
		# arrays is the single biggest win in this hot function. The j-side
		# writes still go straight to the arrays (Newton's third law), and
		# ax[i] already holds their contributions accrued while i was a target,
		# so the flush below is += not =.
		var pxi := px[i]
		var pyi := py[i]
		var pzi := pz[i]
		var mi := m[i]
		var axi := 0.0
		var ayi := 0.0
		var azi := 0.0
		var ti := tau_body[i]   # min over pairs (i',i) already processed, i'<i
		for j in range(i + 1, n):
			var mj := m[j]
			var dx := px[j] - pxi
			var dy := py[j] - pyi
			var dz := pz[j] - pzi
			var r2 := dx * dx + dy * dy + dz * dz + EPS2
			var r3 := r2 * sqrt(r2)
			var f := G / r3
			axi += f * mj * dx
			ayi += f * mj * dy
			azi += f * mj * dz
			ax[j] -= f * mi * dx
			ay[j] -= f * mi * dy
			az[j] -= f * mi * dz
			# dynamical timescale of this pair: tau² = r³ / G(mA+mB).
			var t2 := r3 / (G * (mi + mj))
			if t2 < tau2min:
				tau2min = t2
			# attribute to the lighter member (both when comparable) — see tau_body
			if mj <= mi:
				if t2 < tau_body[j]:
					tau_body[j] = t2
				if t2 < ti and mj > mi * MASS_COMPARABLE:
					ti = t2
			else:
				if t2 < ti:
					ti = t2
				if t2 < tau_body[j] and mi > mj * MASS_COMPARABLE:
					tau_body[j] = t2
		ax[i] += axi
		ay[i] += ayi
		az[i] += azi
		tau_body[i] = ti
	for q in n:
		tau_body[q] = sqrt(tau_body[q])
	tau_min = sqrt(tau2min)


## Conserved quantities of the raw barycentric state — diagnostics only
## (regression tests + perf panel, O(n²)). Potential uses the same EPS2
## softening as compute_accel, so the reported energy is the exact invariant
## of the integrated equations. Scalars stay in 64-bit floats throughout
## (Vector3 would truncate the tiny drifts being measured).
func conserved(g_scale: float) -> Dictionary:
	var n := count()
	var G := Units.GM_SUN * g_scale
	var ke := 0.0
	var pe := 0.0
	var mom_x := 0.0
	var mom_y := 0.0
	var mom_z := 0.0
	var lx := 0.0
	var ly := 0.0
	var lz := 0.0
	for i in n:
		var mi := m[i]
		ke += 0.5 * mi * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i])
		mom_x += mi * vx[i]
		mom_y += mi * vy[i]
		mom_z += mi * vz[i]
		lx += mi * (py[i] * vz[i] - pz[i] * vy[i])
		ly += mi * (pz[i] * vx[i] - px[i] * vz[i])
		lz += mi * (px[i] * vy[i] - py[i] * vx[i])
		for j in range(i + 1, n):
			var dx := px[j] - px[i]
			var dy := py[j] - py[i]
			var dz := pz[j] - pz[i]
			pe -= G * mi * m[j] / sqrt(dx * dx + dy * dy + dz * dz + EPS2)
	return {
		e = ke + pe, ke = ke, pe = pe,
		p_mag = sqrt(mom_x * mom_x + mom_y * mom_y + mom_z * mom_z),
		l_mag = sqrt(lx * lx + ly * ly + lz * lz),
	}


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


## One block of H days with power-of-2 subcycling. Bodies whose tightest pair
## demands a finer step than H (fast moons, close encounters) take k substeps
## of H/k (k ≤ K_MAX) inside the block, while everyone else takes a single
## leapfrog step of H — so one fast moon no longer forces tiny steps on the
## whole system.
##
## The scheme is exact where it matters: between its kicks a slow body drifts
## ballistically, so its position anywhere in the block, p(t) = p(H) − v·(H−t),
## IS its own KDK trajectory — a subcycling moon feels its host's mid-block
## motion with no extra error. The one approximation is that slow bodies feel
## fast bodies only at block boundaries (interior fast kicks are one-sided);
## the resulting momentum error is O(m_fast·(ωH)²), oscillatory and negligible
## at moon masses (the perf harness tracks |P|).
##
## The caller keeps H ≤ (K_MAX/SAFETY)·tau_min, so the tightest body resolves
## at k = K_MAX (h = tau_min/SAFETY — exactly the old global step's finest
## resolution) and no promotion mid-block is needed: any pair tightening toward
## a collision drives tau_min — hence the next block's H — down on its own.
##
## Requires ax/ay/az to hold the accel of the entry positions (every state
## mutation already re-runs compute_accel); leaves the state synchronized at
## t+H with fresh accel + tau, so all external editing keeps working unchanged.
func step_block(H: float, g_scale: float) -> void:
	var n := count()
	if k_sub.size() != n:
		k_sub.resize(n)
	var k_big := 1
	for i in n:
		# smallest power of 2 with H/k ≤ tau_i/SAFETY (tau = INF → k = 1)
		var need := H * SAFETY / tau_body[i]
		var k := 1
		while k < K_MAX and float(k) < need:
			k *= 2
		k_sub[i] = k
		if k > k_big:
			k_big = k
	had_fast = k_big > 1
	last_fast_evals = 0
	if not had_fast:
		leapfrog_substep(H, g_scale)   # everyone cruises → exactly the old step
		return

	if enc_min_r2.size() != n * n:
		enc_min_r2.resize(n * n)
	enc_min_r2.fill(INF)
	var G := Units.GM_SUN * g_scale
	var h_min_step := H / float(k_big)

	# opening half-kick, each body at its own substep size
	for i in n:
		var h2 := H / (2.0 * float(k_sub[i]))
		vx[i] += ax[i] * h2
		vy[i] += ay[i] * h2
		vz[i] += az[i] * h2
	# slow bodies drift the whole block in one go; _accel_on samples their
	# interior positions back along this exact chord
	for i in n:
		if k_sub[i] == 1:
			px[i] += vx[i] * H
			py[i] += vy[i] * H
			pz[i] += vz[i] * H

	# interleaved subcycles, time-ordered across the k_big finest slots
	for s in range(k_big):
		# drift pass first, so same-rung tight pairs see each other at
		# synchronized post-drift positions in the kick pass (exact symmetry)
		for i in n:
			var ki := k_sub[i]
			if ki > 1 and s % (k_big / ki) == 0:
				var h := H / float(ki)
				px[i] += vx[i] * h
				py[i] += vy[i] * h
				pz[i] += vz[i] * h
		# kick pass (interior full kicks = merged adjacent half-kicks); the
		# last substep's closing half-kick is deferred to the block end
		for i in n:
			var ki := k_sub[i]
			if ki > 1 and s % (k_big / ki) == 0:
				var s_next := s + k_big / ki
				if s_next < k_big:
					_accel_on(i, float(s_next) * h_min_step, H, G)
					var h := H / float(ki)
					vx[i] += _f_ax * h
					vy[i] += _f_ay * h
					vz[i] += _f_az * h

	# synchronized block end: full boundary accel (refreshes tau for the next
	# block's classification), then closing half-kicks
	compute_accel(g_scale)
	for i in n:
		var h2 := H / (2.0 * float(k_sub[i]))
		vx[i] += ax[i] * h2
		vy[i] += ay[i] * h2
		vz[i] += az[i] * h2


## Acceleration on subcycling body fi at block-interior time t (days into a
## block of length H): slow bodies are sampled on their drift chords (exact),
## other fast bodies at their current stored positions (staleness < their own
## substep, zero for same-rung partners). Writes _f_ax/_f_ay/_f_az; records
## each pair's min separation² into enc_min_r2 for the collision scan (r² is
## already in hand, so this is nearly free).
func _accel_on(fi: int, t: float, H: float, G: float) -> void:
	var n := count()
	var pxi := px[fi]
	var pyi := py[fi]
	var pzi := pz[fi]
	var axl := 0.0
	var ayl := 0.0
	var azl := 0.0
	var back := H - t
	var base := fi * n
	for j in n:
		if j == fi:
			continue
		var pxj := px[j]
		var pyj := py[j]
		var pzj := pz[j]
		if k_sub[j] == 1:
			pxj -= vx[j] * back
			pyj -= vy[j] * back
			pzj -= vz[j] * back
		var dx := pxj - pxi
		var dy := pyj - pyi
		var dz := pzj - pzi
		var r2 := dx * dx + dy * dy + dz * dz + EPS2
		if r2 < enc_min_r2[base + j]:
			enc_min_r2[base + j] = r2
		var f := G * m[j] / (r2 * sqrt(r2))
		axl += f * dx
		ayl += f * dy
		azl += f * dz
	last_fast_evals += n - 1
	_f_ax = axl
	_f_ay = ayl
	_f_az = azl


## Min real (uncompressed) separation of a pair sampled across the last block's
## subcycles, AU — INF when neither member subcycled (use the endpoint
## real_distance / swept_distance instead).
func enc_distance(i: int, j: int) -> float:
	if not had_fast:
		return INF
	var n := count()
	var r2 := minf(enc_min_r2[i * n + j], enc_min_r2[j * n + i])
	return sqrt(r2) if r2 < INF else INF


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
