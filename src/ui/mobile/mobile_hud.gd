class_name MobileHud
extends CanvasLayer
## Mobile HUD (phones / touch handhelds): a different paradigm from the
## desktop's four-edge panel layout. The 3D scene owns the whole screen; the
## only persistent chrome is a slim status pill (date + mode) up top and a
## five-button action bar along the bottom. Everything else is a bottom sheet:
##   · selection    → BodySheet (non-modal, peeks above the bar, drag to expand)
##   · planet list  → PlanetsSheet (modal)
##   · time speed   → TimeSheet (modal)
##   · menu         → MenuSheet (saves / reset / settings / display / physics)
##   · add body     → the shared AddPanel form, embedded in a sheet
##   · settings     → the shared SettingsPanel content, embedded in a sheet
## The save browser stays the existing full-screen overlay. The Android back
## gesture closes sheets / deselects before it exits the app.

const BAR_H := 66.0

var sim: Simulation
var rig: CameraRig

var bar: MobileBar
var body_sheet: BodySheet
var planets_sheet: PlanetsSheet
var time_sheet: TimeSheet
var menu_sheet: MenuSheet
var add_sheet: MobileSheet
var add_panel: AddPanel
var settings_sheet: MobileSheet
var settings: SettingsPanel
var save_browser: SaveBrowser
var toast: ToastLabel
var hint: Label

var date_label: Label
var badge: Label

var _last_badge := ""
var _lag_toast_shown := false


func setup(sim_: Simulation, rig_: CameraRig = null) -> void:
	sim = sim_
	rig = rig_
	layer = 3
	get_tree().quit_on_go_back = false   # back navigates the UI (handled below)

	_build_status_pill()

	bar = MobileBar.new()
	bar.setup(sim)
	add_child(bar)

	# --- sheets (added after the bar so they slide over it) -----------------
	body_sheet = BodySheet.new()
	body_sheet.bottom_inset = BAR_H
	body_sheet.setup(sim)
	add_child(body_sheet)

	planets_sheet = PlanetsSheet.new()
	planets_sheet.setup(sim)
	add_child(planets_sheet)

	time_sheet = TimeSheet.new()
	time_sheet.setup(sim)
	add_child(time_sheet)

	menu_sheet = MenuSheet.new()
	menu_sheet.setup(sim)
	add_child(menu_sheet)

	add_sheet = MobileSheet.new(true)
	add_sheet.max_ratio = 0.72
	add_child(add_sheet)
	add_panel = AddPanel.new()
	add_panel.embedded = true
	add_panel.setup(sim)
	add_sheet.content.add_child(add_panel)
	# the form's Cancel/Add call close_panel() (visible = false) — fold the
	# sheet with it; swiping the sheet away closes the form the same way
	add_panel.visibility_changed.connect(func() -> void:
		if not add_panel.visible and add_sheet.is_open():
			add_sheet.close())
	add_sheet.closed.connect(func() -> void:
		if add_panel.visible:
			add_panel.close_panel())

	settings_sheet = MobileSheet.new(true)
	settings_sheet.max_ratio = 0.78
	add_child(settings_sheet)
	settings_sheet.add_title("Settings")
	settings = SettingsPanel.new()
	add_child(settings)
	settings.setup(sim, settings_sheet.content)

	save_browser = SaveBrowser.new()
	save_browser.setup(sim, rig)
	add_child(save_browser)

	# --- wiring -------------------------------------------------------------
	bar.menu_pressed.connect(func() -> void: _open_modal(menu_sheet, menu_sheet.open_sheet))
	bar.planets_pressed.connect(func() -> void: _open_modal(planets_sheet, planets_sheet.open_sheet))
	bar.speed_pressed.connect(func() -> void: _open_modal(time_sheet, time_sheet.open))
	# ⊕ mirrors the desktop rail: builds around the current selection
	# (sun/none → a free sun-orbiting body, anything else → a moon of it)
	bar.add_pressed.connect(func() -> void:
		var sel = Events.selected
		open_add(null if sel == null or sel.is_sun else sel))

	menu_sheet.saves_clicked.connect(func() -> void: save_browser.open_browser())
	menu_sheet.reset_clicked.connect(save_browser.do_reset)
	menu_sheet.settings_clicked.connect(func() -> void:
		settings.open_panel()   # embedded: refreshes the controls
		_open_modal(settings_sheet, settings_sheet.open))

	planets_sheet.add_clicked.connect(func() -> void:
		var sel = Events.selected
		open_add(null if sel == null or sel.is_sun else sel))
	planets_sheet.add_moon_clicked.connect(open_add)

	toast = ToastLabel.new()
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.offset_top = 76
	add_child(toast)

	hint = UITheme.make_label(
		"drag to orbit · pinch to zoom · tap a planet to follow",
		10, Color(139 / 255.0, 151 / 255.0, 171 / 255.0, 0.75))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.5
	hint.anchor_right = 0.5
	hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint.offset_top = 52
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)
	var tween := hint.create_tween()
	tween.tween_interval(8.0)
	tween.tween_property(hint, "modulate:a", 0.0, 1.5)

	Events.mode_changed.connect(_update_mode_badge)
	_update_mode_badge()


func _build_status_pill() -> void:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", UITheme.panel_style(14, 14))
	pill.anchor_left = 0.5
	pill.anchor_right = 0.5
	pill.grow_horizontal = Control.GROW_DIRECTION_BOTH
	pill.offset_top = 6
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	date_label = UITheme.make_label("—", 12, UITheme.TEXT)
	date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	date_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(date_label)
	badge = UITheme.make_key_label("Kepler ephemeris")
	badge.add_theme_font_size_override("font_size", 9)
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(badge)
	pill.add_child(col)
	add_child(pill)


## opens one modal sheet, closing any other (only one at a time)
func _open_modal(sheet: MobileSheet, opener: Callable) -> void:
	for s in [planets_sheet, time_sheet, menu_sheet, add_sheet, settings_sheet]:
		if s != sheet and s.is_open():
			if s == add_sheet and add_panel.visible:
				add_panel.close_panel()
			else:
				s.close()
	opener.call()


func open_add(host) -> void:
	add_panel.open_panel(host)
	_open_modal(add_sheet, func() -> void: add_sheet.open(true))


func _update_mode_badge() -> void:
	var text: String
	var gravity := sim.physics_active
	if gravity:
		var g_tag := (" · G×%.2f" % sim.g_scale) if absf(sim.g_scale - 1.0) > 0.005 else ""
		text = "N-body gravity" + g_tag
		# the substep budget couldn't keep up with the requested time speed —
		# the clock is honestly lagging; say so instead of silently slowing
		if sim.lag_ratio < 0.9:
			text += " · limited ×%.1f" % sim.lag_ratio
			if not _lag_toast_shown:
				_lag_toast_shown = true
				Events.toast_requested.emit("Moon physics limits time speed — clock running slower than requested")
	else:
		text = "Kepler ephemeris"
	if text != _last_badge:
		_last_badge = text
		badge.text = text.to_upper()
		badge.add_theme_color_override("font_color",
			UITheme.ACCENT_WARM if gravity else UITheme.MUTED)


func update_live() -> void:
	var dc := Fmt.fmt_date(sim.sim_ms)
	date_label.text = "%s · %s" % [dc[0], dc[1]]
	bar.update_live()
	body_sheet.update_live()
	time_sheet.update_live()
	settings.update_live()
	_update_mode_badge()


## Android back gesture: close the top-most UI surface first; only quit from
## a bare screen
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if save_browser.is_open():
		save_browser.close_browser()
	elif add_sheet.is_open():
		add_panel.close_panel()
	elif settings_sheet.is_open():
		settings_sheet.close()
	elif planets_sheet.is_open():
		planets_sheet.close()
	elif time_sheet.is_open():
		time_sheet.close()
	elif menu_sheet.is_open():
		menu_sheet.close()
	elif Events.selected != null:
		Events.deselect_requested.emit()
	else:
		get_tree().quit()
