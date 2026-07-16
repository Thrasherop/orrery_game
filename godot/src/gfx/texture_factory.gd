class_name TextureFactory
extends Node
## Generates every procedural texture once at startup. Painted textures
## (gas/rocky/earth) are drawn with CanvasItem draw calls into SubViewports —
## a near 1:1 port of the prototype's canvas-2D code — then captured to
## ImageTextures and the viewports freed. Radial glows use GradientTexture2D
## directly; the Saturn ring strip is built per-pixel.

const W := 512
const H := 256

var textures := {}          # key -> Texture2D
var _falloff: ImageTexture  # small radial alpha falloff, reused for blotches


## Painter host: a Control whose _draw defers to a Callable.
class PainterControl extends Control:
	var painter: Callable
	func _draw() -> void:
		painter.call(self)


## Build all textures for the given planet BodyDefs (+ moons + custom palettes).
## Must be awaited before the world views are constructed.
func generate(defs: Array) -> void:
	_falloff = _make_falloff()
	var jobs: Array = []   # [key, viewport]

	for def in defs:
		var kind: String = def.tex.get("kind", "rocky")
		if kind == "gas":
			jobs.append([def.body_name, _make_viewport(_paint_gas.bind(def.tex))])
		elif kind == "earth":
			jobs.append([def.body_name, _make_viewport(_paint_earth)])
		else:
			jobs.append([def.body_name, _make_viewport(_paint_rocky.bind(def.tex))])
		for md in def.moons:
			var cfg := { base = md.color, spots = md.spots }
			jobs.append(["moon:%s:%s" % [def.body_name, md.name], _make_viewport(_paint_rocky.bind(cfg))])

	for i in Catalog.CUSTOM_PALETTES.size():
		jobs.append(["custom%d" % i, _make_viewport(_paint_rocky.bind(Catalog.CUSTOM_PALETTES[i].tex))])

	# let the render server draw everything, then harvest
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	for job in jobs:
		var vp: SubViewport = job[1]
		var img: Image = vp.get_texture().get_image()
		if img == null or img.is_empty():
			textures[job[0]] = _flat_texture(Color(0.5, 0.5, 0.5))   # headless fallback
		else:
			# runtime RGBA8 textures are sampled without sRGB decode in 3D,
			# so store linear data or albedo comes out washed out
			img.srgb_to_linear()
			textures[job[0]] = ImageTexture.create_from_image(img)
		vp.queue_free()

	textures["ring"] = _ring_texture()


func _make_viewport(painter: Callable) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(W, H)
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var c := PainterControl.new()
	c.painter = painter
	c.size = Vector2(W, H)
	vp.add_child(c)
	add_child(vp)
	return vp


static func _flat_texture(col: Color) -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return ImageTexture.create_from_image(img)


## radial alpha falloff (alpha 1 at center → 0 at edge), tinted when drawn
func _make_falloff() -> ImageTexture:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var half := s / 2.0
	for y in s:
		for x in s:
			var d := Vector2(x - half + 0.5, y - half + 0.5).length() / half
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func _vertical_gradient(stops: Array) -> GradientTexture2D:
	var g := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for s in stops:
		offsets.append(s[1])
		colors.append(Color(s[0]))
	g.offsets = offsets
	g.colors = colors
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 8
	t.height = H
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(0, 1)
	return t


# ---------------------------------------------------------------
# painters (run inside PainterControl._draw)
# ---------------------------------------------------------------
func _paint_gas(ci: Control, cfg: Dictionary) -> void:
	ci.draw_texture_rect(_vertical_gradient(cfg.stops), Rect2(0, 0, W, H), false)
	# wavy horizontal streaks
	var streak: float = cfg.get("streak", 0.4)
	var n := int(90.0 * streak + 10.0)
	for i in n:
		var y := randf() * H
		var alpha := 0.03 + randf() * 0.07
		var col := Color(1, 1, 1, alpha) if randf() > 0.5 else Color(30 / 255.0, 20 / 255.0, 10 / 255.0, alpha)
		var width := 1.0 + randf() * 3.0
		var amp := 1.0 + randf() * 4.0
		var freq := 0.01 + randf() * 0.03
		var ph := randf() * 9.0
		var pts := PackedVector2Array()
		var x := 0.0
		while x <= W:
			pts.append(Vector2(x, y + sin(x * freq + ph) * amp))
			x += 8.0
		ci.draw_polyline(pts, col, width, true)
	if cfg.has("spot"):   # great red spot
		var sx := W * 0.68
		var sy := H * 0.63
		var r := 26.0
		while r > 4.0:
			var c := Color(cfg.spot)
			c.a = (38.0 + (26.0 - r) * 7.0) / 255.0
			ci.draw_set_transform(Vector2(sx, sy), 0.0, Vector2(r * 1.55, r * 0.85))
			ci.draw_circle(Vector2.ZERO, 1.0, c)
			r -= 4.0
		ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _paint_rocky(ci: Control, cfg: Dictionary) -> void:
	ci.draw_rect(Rect2(0, 0, W, H), Color(cfg.base))
	# soft blotches
	for i in 140:
		var col := Color(cfg.spots[randi() % cfg.spots.size()])
		col.a = 0x55 / 255.0
		var r := 6.0 + randf() * 34.0
		var pos := Vector2(randf() * W, randf() * H)
		ci.draw_texture_rect(_falloff, Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), false, col)
	# fine speckle / craters
	for i in 2600:
		var a := 0.04 + randf() * 0.09
		var c := Color(0, 0, 0, a) if randf() > 0.5 else Color(1, 1, 1, a * 0.7)
		ci.draw_circle(Vector2(randf() * W, randf() * H), randf() * 1.6, c)


func _paint_earth(ci: Control) -> void:
	ci.draw_texture_rect(
		_vertical_gradient([["#123a6b", 0.0], ["#17518f", 0.5], ["#123a6b", 1.0]]),
		Rect2(0, 0, W, H), false)
	# continents: clusters of overlapping blobs
	var land_cols := ["#3e7d3a", "#4c8a42", "#7c8a4a", "#987f52"]
	for i in 15:
		var cx := randf() * W
		var cy := H * 0.18 + randf() * H * 0.64
		var n := 6 + randi() % 14
		for j in n:
			var col := Color(land_cols[randi() % land_cols.size()])
			col.a = 0xe8 / 255.0
			var r := 5.0 + randf() * 17.0
			ci.draw_circle(Vector2(cx + (randf() - 0.5) * 72.0, cy + (randf() - 0.5) * 40.0), r, col)
	# polar caps
	ci.draw_rect(Rect2(0, 0, W, 13), Color(240 / 255.0, 246 / 255.0, 252 / 255.0, 0.95))
	ci.draw_rect(Rect2(0, H - 16, W, 16), Color(240 / 255.0, 246 / 255.0, 252 / 255.0, 0.95))
	ci.draw_rect(Rect2(0, 13, W, 7), Color(240 / 255.0, 246 / 255.0, 252 / 255.0, 0.5))
	ci.draw_rect(Rect2(0, H - 23, W, 7), Color(240 / 255.0, 246 / 255.0, 252 / 255.0, 0.5))
	# clouds
	for i in 90:
		var col := Color(1, 1, 1, 0.05 + randf() * 0.12)
		var pos := Vector2(randf() * W, randf() * H)
		ci.draw_set_transform(pos, 0.0, Vector2(8.0 + randf() * 26.0, 2.0 + randf() * 5.0))
		ci.draw_circle(Vector2.ZERO, 1.0, col)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# ---------------------------------------------------------------
# per-pixel textures
# ---------------------------------------------------------------
## Saturn's rings: a 512x8 radial strip (u follows radius on the ring mesh)
static func _ring_texture() -> ImageTexture:
	var img := Image.create(W, 8, false, Image.FORMAT_RGBA8)
	var bands := [
		[0.00, 0.10, Color(180 / 255.0, 160 / 255.0, 130 / 255.0, 0.10)],
		[0.12, 0.28, Color(210 / 255.0, 190 / 255.0, 155 / 255.0, 0.55)],
		[0.30, 0.44, Color(190 / 255.0, 170 / 255.0, 140 / 255.0, 0.72)],
		[0.46, 0.50, Color(120 / 255.0, 105 / 255.0, 85 / 255.0, 0.15)],
		[0.52, 0.72, Color(225 / 255.0, 205 / 255.0, 170 / 255.0, 0.80)],
		[0.74, 0.78, Color(150 / 255.0, 132 / 255.0, 105 / 255.0, 0.25)],
		[0.80, 0.94, Color(205 / 255.0, 185 / 255.0, 150 / 255.0, 0.55)],
		[0.96, 1.00, Color(170 / 255.0, 150 / 255.0, 120 / 255.0, 0.20)],
	]
	for band in bands:
		for x in range(int(band[0] * W), int(band[1] * W)):
			for y in 8:
				img.set_pixel(x, y, band[2])
	# fine grooves: black with random alpha composited source-over
	for i in 220:
		var x := randi() % W
		var a := randf() * 0.16
		for y in 8:
			var c := img.get_pixel(x, y)
			var oa := a + c.a * (1.0 - a)
			if oa <= 0.0:
				continue
			var k := c.a * (1.0 - a) / oa
			img.set_pixel(x, y, Color(c.r * k, c.g * k, c.b * k, oa))
	img.srgb_to_linear()
	return ImageTexture.create_from_image(img)


## radial glow: inner color → outer color at 25% → transparent.
## NOT linearized on purpose: the prototype's glowTexture skipped the sRGB
## tag, so three.js sampled the raw values as linear — that bright warm look
## is part of the game's character.
static func make_glow(inner: Color, outer: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 1.0])
	g.colors = PackedColorArray([inner, outer, Color(0, 0, 0, 0)])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 256
	t.height = 256
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t
