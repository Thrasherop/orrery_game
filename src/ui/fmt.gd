class_name Fmt
## Formatting + slider-mapping helpers shared by the HUD panels.

const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

const SPEED_MIN := 1.0
const SPEED_MAX := 2e8


## -> [date string, clock string] (UTC)
static func fmt_date(ms: float) -> Array:
	var secs := int(floor(ms / 1000.0))
	var d := Time.get_datetime_dict_from_unix_time(secs)
	if d.is_empty():
		return ["—", "—"]
	return [
		"%s %d, %d" % [MONTHS[d.month - 1], d.day, d.year],
		"%02d:%02d:%02d UTC" % [d.hour, d.minute, d.second],
	]


static func fmt_speed(s: float) -> String:
	if s < 60.0:
		return ("%.1f sec / s" % s) if s < 10.0 else ("%.0f sec / s" % s)
	if s < 3600.0:
		return "%.1f min / s" % (s / 60.0)
	if s < 86400.0:
		return "%.1f hr / s" % (s / 3600.0)
	if s < 31557600.0:
		return "%.1f days / s" % (s / 86400.0)
	return "%.2f yrs / s" % (s / 31557600.0)


## thousands separators, e.g. 696,340
static func fmt_big(n: float) -> String:
	var neg := n < 0.0
	var s := str(int(round(absf(n))))
	var out := ""
	var cnt := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		cnt += 1
		if cnt % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if neg else out


# time-speed slider (log scale, 1 – 2e8 sim-seconds per second)
static func speed_to_slider(s: float) -> float:
	return 1000.0 * log(s / SPEED_MIN) / log(SPEED_MAX / SPEED_MIN)


static func slider_to_speed(v: float) -> float:
	return SPEED_MIN * pow(SPEED_MAX / SPEED_MIN, v / 1000.0)


# add-panel distance slider (log scale, 0.1 – 40 AU)
static func dist_to_slider(d: float) -> float:
	return 1000.0 * log(clampf(d, 0.1, 40.0) / 0.1) / log(400.0)


static func slider_to_dist(v: float) -> float:
	return 0.1 * pow(400.0, v / 1000.0)


# add-moon distance slider (log scale, 0.5 – 30 ×10⁻³ AU)
static func moon_dist_to_slider(d: float) -> float:
	return 1000.0 * log(clampf(d, 0.5, 30.0) / 0.5) / log(60.0)


static func slider_to_moon_dist(v: float) -> float:
	return 0.5 * pow(60.0, v / 1000.0)
