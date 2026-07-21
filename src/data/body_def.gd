class_name BodyDef
extends Resource
## Static definition of a celestial body: orbital elements, physical stats,
## and visual configuration. Built in code by Catalog.

var body_name := ""
var color := Color.WHITE
var el := {}              # Keplerian elements: {a,e,i,L,w,O} each [J2000 value, rate/century]
var size := 1.0           # exaggerated display radius
var tilt := 0.0           # axial tilt, degrees
var day_hours := 24.0     # negative = retrograde spin
var radius_km := 0.0
var period_days := 0.0    # 0 = none (sun)
var body_type := ""
var desc := ""
var tex := {}             # {kind:"gas"|"rocky"|"earth", ...} procedural texture cfg
var moons: Array = []     # of Dictionary {name,size,dist,period,incl,color,spots}
var has_rings := false


static func make(cfg: Dictionary) -> BodyDef:
	var d := BodyDef.new()
	d.body_name = cfg.name
	d.color = Color(cfg.color)
	d.el = cfg.get("el", {})
	d.size = cfg["size"]   # ["size"] — dot access would hit Dictionary.size()
	d.tilt = cfg.tilt
	d.day_hours = cfg.day_hours
	d.radius_km = cfg.get("radius_km", 0.0)
	d.period_days = cfg.get("period_days", 0.0)
	d.body_type = cfg.type
	d.desc = cfg.desc
	d.tex = cfg.get("tex", {})
	d.moons = cfg.get("moons", [])
	d.has_rings = cfg.get("rings", false)
	return d
