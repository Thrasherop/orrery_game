class_name Kepler
## Orbital mechanics — Keplerian elements (J2000, Standish/NASA, valid
## 1800–2050). Positions are computed analytically from the simulated Julian
## date, so planetary motion, eccentricity and inclination are astronomically
## correct.
##
## All positions are returned as [x, y, z] Arrays of 64-bit floats in SCENE
## axes (y up): ecliptic (x, y, z) → scene (x, z, -y). Vector3 is only 32-bit,
## so the physics seeding path stays in doubles.


static func solve_kepler(M: float, e: float) -> float:
	var E := M if e < 0.8 else PI
	for k in 10:
		var d := (E - e * sin(E) - M) / (1.0 - e * cos(E))
		E -= d
		if abs(d) < 1e-8:
			break
	return E


## el is a Dictionary of [value at J2000, rate per Julian century] pairs.
static func elements_at(el: Dictionary, T: float) -> Dictionary:
	return {
		a = el.a[0] + el.a[1] * T,
		e = el.e[0] + el.e[1] * T,
		i = (el.i[0] + el.i[1] * T) * Units.DEG,
		L = (el.L[0] + el.L[1] * T) * Units.DEG,
		w = (el.w[0] + el.w[1] * T) * Units.DEG,
		O = (el.O[0] + el.O[1] * T) * Units.DEG,
	}


## heliocentric ecliptic position (AU) → scene axes (y up), as doubles
static func orbital_position(p: Dictionary, E: float) -> Array:
	var xp: float = p.a * (cos(E) - p.e)
	var yp: float = p.a * sqrt(1.0 - p.e * p.e) * sin(E)
	var om: float = p.w - p.O
	var cw := cos(om)
	var sw := sin(om)
	var cO := cos(p.O)
	var sO := sin(p.O)
	var ci := cos(p.i)
	var si := sin(p.i)
	var x := (cw * cO - sw * sO * ci) * xp + (-sw * cO - cw * sO * ci) * yp
	var y := (cw * sO + sw * cO * ci) * xp + (-sw * sO + cw * cO * ci) * yp
	var z := (sw * si) * xp + (cw * si) * yp
	# eclipticToScene: (x, y, z) -> (x, z, -y)
	return [x, z, -y]


static func body_position_au(el: Dictionary, T: float) -> Array:
	var p := elements_at(el, T)
	var M := fmod(p.L - p.w, TAU)
	if M > PI:
		M -= TAU
	if M < -PI:
		M += TAU
	return orbital_position(p, solve_kepler(M, p.e))


static func body_position_v3(el: Dictionary, T: float) -> Vector3:
	var a := body_position_au(el, T)
	return Vector3(a[0], a[1], a[2])


## position & velocity from Kepler elements via central difference.
## Returns { p: [x,y,z] AU, v: [x,y,z] AU/day } in scene axes, doubles.
static func state_vector(el: Dictionary, T: float) -> Dictionary:
	var h := 0.01          # days
	var CD := 36525.0      # days per Julian century
	var p := body_position_au(el, T)
	var pm := body_position_au(el, T - h / CD)
	var pp := body_position_au(el, T + h / CD)
	var inv := 1.0 / (2.0 * h)
	return {
		p = p,
		v = [(pp[0] - pm[0]) * inv, (pp[1] - pm[1]) * inv, (pp[2] - pm[2]) * inv],
	}
