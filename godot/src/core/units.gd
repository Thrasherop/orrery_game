class_name Units
## Physical constants and the display-distance compression used by the whole app.
## Display distances are compressed (r^0.62) and planet sizes exaggerated so
## everything is visible at once — standard orrery practice.

const DEG := PI / 180.0
const AU_KM := 149597870.7

const GM_SUN := 2.9591220828559e-4   # AU³/day² (Gaussian gravitational constant²)
const EARTH_SOLAR := 3.003e-6        # Earth masses → solar masses
const KMS_PER_AUDAY := 1731.456      # AU/day → km/s

const DIST_K := 26.0
const DIST_P := 0.62                 # display-distance compression


static func dist_scale(r_au: float) -> float:
	return DIST_K * pow(r_au, DIST_P)


## heliocentric/barycentric AU vector (scene axes) → compressed display vector
static func to_display(v_au: Vector3) -> Vector3:
	var r := v_au.length()
	if r < 1e-9:
		return Vector3.ZERO
	return v_au * (dist_scale(r) / r)
