class_name MoonMath
## Circular-orbit math for simulated moons, shared by the sim (kinematics +
## physics seeding), the add-moon panel/preview and the info card so they all
## agree exactly. Everything works in scalar GDScript floats (64-bit) — the
## relative offsets are ~1e-3 AU, too small for Vector3's 32-bit components.
##
## Orbit basis matches the decorative pivots in BodyView (Rz(incl) applied to
## (cos θ, 0, -sin θ)): U = (cos i, sin i, 0), V = (0, 0, -1).


## circular angular rate, rad/day (positive; caller applies orbit_sign)
static func omega(a_au: float, host_mass_solar: float, moon_mass_solar: float, g_scale: float) -> float:
	return sqrt(Units.GM_SUN * g_scale * (host_mass_solar + moon_mass_solar) / (a_au * a_au * a_au))


static func derived_period_days(a_au: float, host_mass_solar: float, moon_mass_solar: float, g_scale: float) -> float:
	return TAU / omega(a_au, host_mass_solar, moon_mass_solar, g_scale)


## host-relative state on the inclined circle at phase angle theta.
## omega_signed < 0 = retrograde. Returns { p: [x,y,z] AU, v: [x,y,z] AU/day }.
static func rel_state(a_au: float, incl_deg: float, theta: float, omega_signed: float) -> Dictionary:
	var ci := cos(incl_deg * Units.DEG)
	var si := sin(incl_deg * Units.DEG)
	var ct := cos(theta)
	var st := sin(theta)
	var p := [a_au * ct * ci, a_au * ct * si, -a_au * st]
	var s := a_au * omega_signed
	var v := [-s * st * ci, -s * st * si, -s * ct]
	return { p = p, v = v }


## display amplification when a moon is captured by a body it wasn't
## catalogued around: place it just outside the captor's rendered sphere
static func capture_disp_k(host_size: float, moon_size: float, r_au: float) -> float:
	return clampf((host_size * 1.8 + moon_size * 3.0) / maxf(r_au, 1e-9), 1.0, 2000.0)


static func hill_radius_au(d_sun_au: float, m_host: float, m_sun: float) -> float:
	return d_sun_au * pow(m_host / (3.0 * m_sun), 1.0 / 3.0)


## display amplification for a user-added moon: the placement distance (log
## scale over the add panel's 0.5–30 ×10⁻³ AU range) maps to a visual
## distance of 1.5–4× the host's rendered radius, so farther moons look
## farther without leaving the host's neighbourhood on screen.
static func add_disp_k(host_size: float, d_au: float) -> float:
	var t := clampf(log(d_au / 0.0005) / log(0.03 / 0.0005), 0.0, 1.0)
	return host_size * lerpf(1.5, 4.0, t) / maxf(d_au, 1e-9)
