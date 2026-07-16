class_name SimTime
## Conversions between simulated Unix milliseconds, Julian centuries (J2000)
## and simulated days. All values are 64-bit floats in GDScript.


static func julian_centuries(ms: float) -> float:
	return (ms / 86400000.0 + 2440587.5 - 2451545.0) / 36525.0


static func sim_days(ms: float) -> float:
	return ms / 86400000.0


## sim-day → Julian centuries
static func day_to_t(d: float) -> float:
	return (d + 2440587.5 - 2451545.0) / 36525.0
