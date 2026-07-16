class_name Catalog
## The solar system data set — J2000 Keplerian elements (Standish/NASA,
## valid 1800–2050), physical stats, descriptions and procedural-texture
## configs, ported verbatim from the prototype.

const PLANET_MASS := {                # solar masses
	"Mercury": 1.660e-7, "Venus": 2.448e-6, "Earth": 3.040e-6, "Mars": 3.227e-7,
	"Jupiter": 9.548e-4, "Saturn": 2.859e-4, "Uranus": 4.366e-5, "Neptune": 5.151e-5,
}

const CUSTOM_PALETTES := [
	{ color = "8fd0a0", tex = { base = "#5f9c72", spots = ["#487d59", "#79b78b", "#3e6b4c"] } },
	{ color = "d68fb8", tex = { base = "#a4587e", spots = ["#87476a", "#c07399", "#6e3a57"] } },
	{ color = "94a8e8", tex = { base = "#5a6fb4", spots = ["#485a96", "#7386cc", "#3c4b7e"] } },
	{ color = "e8c07a", tex = { base = "#b98d4e", spots = ["#96703c", "#d1a866", "#7c5c32"] } },
	{ color = "8fd8d8", tex = { base = "#569e9e", spots = ["#448181", "#74baba", "#386a6a"] } },
]


static func make_sun() -> BodyDef:
	return BodyDef.make({
		name = "Sun", color = "ffc46b", type = "G-type main-sequence star",
		desc = "A 4.6-billion-year-old fusion reactor holding 99.86% of the solar system’s mass. Light from its surface reaches Earth in 8.3 minutes.",
		radius_km = 696340.0, day_hours = 609.1, tilt = 7.25, period_days = 0.0, size = 5.0,
	})


# [value at J2000, rate per Julian century]
static func make_planets() -> Array:
	var out: Array = []

	out.append(BodyDef.make({
		name = "Mercury", color = "b9a389",
		el = { a = [0.38709927, 0.00000037], e = [0.20563593, 0.00001906], i = [7.00497902, -0.00594749],
			L = [252.25032350, 149472.67411175], w = [77.45779628, 0.16047689], O = [48.33076593, -0.12534081] },
		size = 0.55, tilt = 0.03, day_hours = 1407.6, radius_km = 2440.0, period_days = 87.97,
		type = "Terrestrial planet",
		desc = "The smallest planet and closest to the Sun — a cratered, airless world where a single day lasts two of its years.",
		tex = { kind = "rocky", base = "#8a7a68", spots = ["#6e6152", "#a4937d", "#5c5245"] },
	}))

	out.append(BodyDef.make({
		name = "Venus", color = "e6c88f",
		el = { a = [0.72333566, 0.00000390], e = [0.00677672, -0.00004107], i = [3.39467605, -0.00078890],
			L = [181.97909950, 58517.81538729], w = [131.60246718, 0.00268329], O = [76.67984255, -0.27769418] },
		size = 0.86, tilt = 177.4, day_hours = -5832.5, radius_km = 6052.0, period_days = 224.70,
		type = "Terrestrial planet",
		desc = "Shrouded in reflective sulfuric-acid clouds over a crushing CO₂ atmosphere. It spins backwards, slower than it orbits.",
		tex = { kind = "gas", stops = [["#e8cf9a", 0.0], ["#dcbe82", 0.3], ["#eed9ab", 0.55], ["#d3b273", 0.8], ["#e4c992", 1.0]], streak = 0.35 },
	}))

	out.append(BodyDef.make({
		name = "Earth", color = "6fa8dc",
		el = { a = [1.00000261, 0.00000562], e = [0.01671123, -0.00004392], i = [-0.00001531, -0.01294668],
			L = [100.46457166, 35999.37244981], w = [102.93768193, 0.32327364], O = [0.0, 0.0] },
		size = 0.9, tilt = 23.44, day_hours = 23.934, radius_km = 6371.0, period_days = 365.25,
		type = "Terrestrial planet",
		desc = "The only known world with liquid-water oceans and life. Its large moon stabilises the axial tilt that gives it seasons.",
		tex = { kind = "earth" },
		moons = [{ name = "Moon", size = 0.28, dist = 2.3, period = 27.321661, incl = 5.1, color = "#9a9a96", spots = ["#7d7d78", "#b3b3ae", "#6b6b66"] }],
	}))

	out.append(BodyDef.make({
		name = "Mars", color = "d48a5e",
		el = { a = [1.52371034, 0.00001847], e = [0.09339410, 0.00007882], i = [1.84969142, -0.00813131],
			L = [-4.55343205, 19140.30268499], w = [-23.94362959, 0.44441088], O = [49.55953891, -0.29257343] },
		size = 0.65, tilt = 25.19, day_hours = 24.62, radius_km = 3390.0, period_days = 686.98,
		type = "Terrestrial planet",
		desc = "The rust-red desert world, home to the solar system’s tallest volcano and deepest canyon — and dozens of robot explorers.",
		tex = { kind = "rocky", base = "#b5563a", spots = ["#8f4530", "#cf7a52", "#7a3a28", "#d9926a"] },
	}))

	out.append(BodyDef.make({
		name = "Jupiter", color = "d9b38c",
		el = { a = [5.20288700, -0.00011607], e = [0.04838624, -0.00013253], i = [1.30439695, -0.00183714],
			L = [34.39644051, 3034.74612775], w = [14.72847983, 0.21252668], O = [100.47390909, 0.20469106] },
		size = 2.9, tilt = 3.13, day_hours = 9.93, radius_km = 69911.0, period_days = 4332.6,
		type = "Gas giant",
		desc = "More massive than every other planet combined. The Great Red Spot is a storm wider than Earth that has raged for centuries.",
		tex = { kind = "gas", stops = [["#c8a27c", 0.0], ["#e2c8a4", 0.14], ["#a97f5c", 0.26], ["#e8d3b0", 0.38], ["#b58763", 0.52], ["#dcc09a", 0.64], ["#966a4e", 0.72], ["#caa27a", 0.78], ["#e5cca8", 0.9], ["#b08258", 1.0]], streak = 0.8, spot = "#c65f3f" },
		moons = [
			{ name = "Io", size = 0.16, dist = 3.7, period = 1.769, incl = 2.0, color = "#d8b84a", spots = ["#b7952f", "#e8d078", "#96712a"] },
			{ name = "Europa", size = 0.14, dist = 4.3, period = 3.551, incl = 1.0, color = "#cbb9a0", spots = ["#b39f85", "#e0d3bf", "#a08b70"] },
			{ name = "Ganymede", size = 0.22, dist = 5.0, period = 7.155, incl = 2.5, color = "#8f8a80", spots = ["#767268", "#a8a298", "#5f5b52"] },
			{ name = "Callisto", size = 0.20, dist = 5.8, period = 16.689, incl = 2.0, color = "#6b6257", spots = ["#544c42", "#847a6d", "#453e35"] },
		],
	}))

	out.append(BodyDef.make({
		name = "Saturn", color = "e3cfa3",
		el = { a = [9.53667594, -0.00125060], e = [0.05386179, -0.00050991], i = [2.48599187, 0.00193609],
			L = [49.95424423, 1222.49362201], w = [92.59887831, -0.41897216], O = [113.66242448, -0.28867794] },
		size = 2.5, tilt = 26.73, day_hours = 10.66, radius_km = 58232.0, period_days = 10759.2,
		type = "Gas giant",
		desc = "Less dense than water, ringed by billions of shards of nearly pure ice — the remains of a shattered moon or comet.",
		tex = { kind = "gas", stops = [["#dcc296", 0.0], ["#ead6ac", 0.2], ["#cfae7e", 0.38], ["#e8d4a8", 0.55], ["#d4b586", 0.72], ["#e2c99c", 0.88], ["#c9a878", 1.0]], streak = 0.5 },
		rings = true,
		moons = [{ name = "Titan", size = 0.20, dist = 6.9, period = 15.945, incl = 3.0, color = "#c9973f", spots = ["#a87c2e", "#ddb35e", "#8f6825"] }],
	}))

	out.append(BodyDef.make({
		name = "Uranus", color = "9bd4d6",
		el = { a = [19.18916464, -0.00196176], e = [0.04725744, -0.00004397], i = [0.77263783, -0.00242939],
			L = [313.23810451, 428.48202785], w = [170.95427630, 0.40805281], O = [74.01692503, 0.04240589] },
		size = 1.7, tilt = 97.77, day_hours = -17.24, radius_km = 25362.0, period_days = 30688.5,
		type = "Ice giant",
		desc = "Tipped completely on its side, it rolls around the Sun — each pole gets 42 years of daylight followed by 42 of night.",
		tex = { kind = "gas", stops = [["#a8dcde", 0.0], ["#8fcccf", 0.4], ["#b8e4e5", 0.7], ["#9ad2d4", 1.0]], streak = 0.15 },
	}))

	out.append(BodyDef.make({
		name = "Neptune", color = "5f83e0",
		el = { a = [30.06992276, 0.00026291], e = [0.00859048, 0.00005105], i = [1.77004347, 0.00035372],
			L = [-55.12002969, 218.45945325], w = [44.96476227, -0.32241464], O = [131.78422574, -0.00508664] },
		size = 1.65, tilt = 28.32, day_hours = 16.11, radius_km = 24622.0, period_days = 60182.0,
		type = "Ice giant",
		desc = "The most distant planet, whipped by supersonic winds of over 2,000 km/h — the fastest in the solar system.",
		tex = { kind = "gas", stops = [["#4a6fd4", 0.0], ["#6488e4", 0.3], ["#3f60c2", 0.55], ["#6d90ea", 0.8], ["#5578d8", 1.0]], streak = 0.3 },
		moons = [{ name = "Triton", size = 0.15, dist = 2.7, period = -5.877, incl = 23.0, color = "#b8a8a4", spots = ["#9c8d89", "#d0c2be", "#857773"] }],
	}))

	return out
