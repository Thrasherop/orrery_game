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
# r^0.62 has an unbounded derivative as r -> 0, so tiny real offsets get
# amplified into large, direction-unstable display jumps. That never showed
# up in Kepler mode (heliocentric r is always >= Mercury's 0.39 AU there),
# but in N-body mode every body's display position is relative to the
# barycenter, and the sun's own barycentric wobble (and any body swinging
# close past it in an encounter) legitimately gets arbitrarily close to
# zero. Below this radius, blend to a linear ramp (value-continuous with
# the curve above it) so the derivative stays bounded — well under the
# 0.08 AU minimum placement distance, so normal orbits are unaffected.
const DIST_R0 := 0.02


static func dist_scale(r_au: float) -> float:
	if r_au <= 0.0:
		return 0.0
	if r_au < DIST_R0:
		return DIST_K * pow(DIST_R0, DIST_P) * (r_au / DIST_R0)
	return DIST_K * pow(r_au, DIST_P)


## heliocentric/barycentric AU vector (scene axes) → compressed display vector
static func to_display(v_au: Vector3) -> Vector3:
	var r := v_au.length()
	if r < 1e-9:
		return Vector3.ZERO
	return v_au * (dist_scale(r) / r)
