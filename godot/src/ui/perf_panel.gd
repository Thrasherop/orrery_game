class_name PerfPanel
extends PanelContainer
## Physics-load panel (bottom-left edge drawer, tucked away by default):
## names the bodies forcing the N-body integrator to take smaller substeps —
## the ones to put on rails (or remove) when the clock can't keep up.

const REFRESH_S := 0.5
const MAX_ROWS := 6

var sim: Simulation
var _status: Label
var _stats: Label
var _rows_box: VBoxContainer
var _hint: Label
var _accum := 0.0


func setup(sim_: Simulation) -> void:
	sim = sim_
	add_theme_stylebox_override("panel", UITheme.panel_style())
	custom_minimum_size = Vector2(252, 0)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(UITheme.make_key_label("Physics load"))
	_status = UITheme.make_label("—", 10, UITheme.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(228, 0)
	box.add_child(_status)
	_stats = UITheme.make_label("", 9, UITheme.MUTED)
	_stats.modulate.a = 0.8
	_stats.visible = false
	box.add_child(_stats)
	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 3)
	box.add_child(_rows_box)
	_hint = UITheme.make_label(
		"Tight fast orbits force tiny physics steps. Untick “Simulated” in a body's card to put it on rails.",
		9, UITheme.MUTED)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.custom_minimum_size = Vector2(228, 0)
	_hint.modulate.a = 0.8
	_hint.visible = false
	box.add_child(_hint)
	_refresh()


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= REFRESH_S:
		_accum = 0.0
		_refresh()


func _refresh() -> void:
	for c in _rows_box.get_children():
		_rows_box.remove_child(c)
		c.queue_free()
	if not sim.physics_active:
		_status.text = "Kepler ephemeris — planets ride exact rails, nothing to integrate."
		_stats.visible = false
		_hint.visible = false
		return
	var p: Dictionary = sim.perf
	if p.is_empty():
		_stats.visible = false
	else:
		var ms: float = (p.us_step + p.us_display + p.us_collide + p.us_trails) / 1000.0
		_stats.text = "%d blocks/frame · %s pair forces · %.1f ms" % [
			p.steps, Fmt.fmt_big(p.pair_evals), ms]
		_stats.visible = true
	var costs := sim.step_costs()
	if sim.lag_ratio < 0.9:
		_status.text = "Physics-limited: clock running at ×%.1f of the requested speed." % sim.lag_ratio
	elif costs.is_empty():
		_status.text = "N-body gravity at full speed — nothing is forcing small steps."
	else:
		_status.text = "N-body gravity keeping up at the current time speed."
	_hint.visible = not costs.is_empty()
	for k in mini(costs.size(), MAX_ROWS):
		var c: Dictionary = costs[k]
		_rows_box.add_child(_row(c.body, c.factor))


func _row(b: SimBody, factor: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var dot := Panel.new()
	dot.custom_minimum_size = Vector2(7, 7)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = b.color
	dsb.set_corner_radius_all(3)
	dot.add_theme_stylebox_override("panel", dsb)
	row.add_child(dot)
	var name_lbl := UITheme.make_label(b.body_name, 11, UITheme.TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	var cost := UITheme.make_label("×%s steps" % Fmt.fmt_big(roundf(factor)) if factor >= 10.0 else "×%.1f steps" % factor, 11, UITheme.ACCENT_WARM)
	row.add_child(cost)
	return row
