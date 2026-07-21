class_name SaveBrowser
extends CanvasLayer
## Full-screen save/load overlay: browse saves in nested folders, search by
## name, save-as / quick-save / load / rename / duplicate / move / delete,
## per-save checkpoint history, and Reset. Large touch targets — this is the
## screen the Android UX depends on.
##
## Layer 4: above the HUD (3), below ConfirmPanel (5). The dim ColorRect
## swallows pointer events so camera gestures can't fire underneath.

enum Mode { BROWSE, MOVE, CHECKPOINTS }

var sim: Simulation
var rig: CameraRig
var store := SaveStore.new()

var current_path := ""   # rel path of the loaded save ("" = nothing loaded)
var current_name := ""

var _mode := Mode.BROWSE
var _dir := ""            # folder shown in BROWSE/MOVE mode
var _move_path := ""      # save being moved (MOVE mode)
var _move_name := ""
var _cp_path := ""        # save whose checkpoints are open (CHECKPOINTS mode)
var _cp_name := ""
var _expanded := ""       # save/folder rel path whose action strip is open

var _panel: PanelContainer
var _loaded_lbl: Label
var _quick_btn: Button
var _search: LineEdit
var _subhead: HBoxContainer
var _name_form: PanelContainer
var _name_title: Label
var _name_edit: LineEdit
var _name_cb := Callable()
var _scroll: ScrollContainer
var _list: VBoxContainer


func setup(sim_: Simulation, rig_: CameraRig) -> void:
	sim = sim_
	rig = rig_
	layer = 4
	visible = false

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed:
			close_browser())
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)

	# --- header -----------------------------------------------------------
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	box.add_child(header)
	header.add_child(UITheme.make_label("Saves", 16, UITheme.TEXT))
	_loaded_lbl = UITheme.make_label("", 11, UITheme.MUTED)
	_loaded_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loaded_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_loaded_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_loaded_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_loaded_lbl)
	var close_btn := Button.new()
	close_btn.text = "✕"
	UITheme.style_chip(close_btn, 14)
	close_btn.custom_minimum_size = Vector2(44, 44) if UITheme.touch else Vector2(32, 32)
	close_btn.pressed.connect(close_browser)
	header.add_child(close_btn)

	# --- actions ----------------------------------------------------------
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	box.add_child(actions)
	_quick_btn = _action_btn(actions, "Quick save", UITheme.style_primary, quick_save)
	_action_btn(actions, "Save as…", UITheme.style_ghost, _save_as)
	_action_btn(actions, "Checkpoint", UITheme.style_ghost, _quick_checkpoint)
	_action_btn(actions, "Reset", UITheme.style_danger, do_reset)

	# --- search -----------------------------------------------------------
	_search = LineEdit.new()
	_search.placeholder_text = "Search saves…"
	_search.clear_button_enabled = true
	_search.custom_minimum_size = Vector2(0, 42) if UITheme.touch else Vector2(0, 32)
	_search.add_theme_font_size_override("font_size", UITheme.fs(12))
	_search.text_changed.connect(func(_t: String) -> void:
		_expanded = ""
		_refresh())
	box.add_child(_search)

	# --- breadcrumbs / mode subheader --------------------------------------
	_subhead = HBoxContainer.new()
	_subhead.add_theme_constant_override("separation", 4)
	box.add_child(_subhead)

	# --- inline name form (save-as / rename / duplicate / new folder) ------
	_name_form = PanelContainer.new()
	_name_form.add_theme_stylebox_override("panel", UITheme.flat_style(Color(1, 1, 1, 0.05), 10))
	_name_form.visible = false
	box.add_child(_name_form)
	var nf := VBoxContainer.new()
	nf.add_theme_constant_override("separation", 6)
	_name_form.add_child(nf)
	_name_title = UITheme.make_label("", 11, UITheme.ACCENT)
	nf.add_child(_name_title)
	var nfrow := HBoxContainer.new()
	nfrow.add_theme_constant_override("separation", 8)
	nf.add_child(nfrow)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, 42) if UITheme.touch else Vector2(0, 30)
	_name_edit.add_theme_font_size_override("font_size", UITheme.fs(12))
	_name_edit.text_submitted.connect(func(_t: String) -> void: _name_form_ok())
	nfrow.add_child(_name_edit)
	var nf_cancel := Button.new()
	nf_cancel.text = "Cancel"
	UITheme.style_ghost(nf_cancel)
	nf_cancel.pressed.connect(func() -> void: _name_form.visible = false)
	nfrow.add_child(nf_cancel)
	var nf_ok := Button.new()
	nf_ok.text = "OK"
	UITheme.style_primary(nf_ok)
	nf_ok.pressed.connect(_name_form_ok)
	nfrow.add_child(nf_ok)

	# --- list ---------------------------------------------------------------
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 2)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_list)


func _ready() -> void:
	get_viewport().size_changed.connect(_update_layout)
	_update_layout()


## the overlay is a fixed fraction of the (already UX-scaled) viewport —
## effectively full-screen on phones, a large centered sheet on desktop
func _update_layout() -> void:
	if not is_inside_tree():
		return
	var vp := get_viewport().get_visible_rect().size
	var w := minf(vp.x * 0.94, 560.0)
	var h := vp.y * 0.9 if UITheme.touch else minf(vp.y * 0.85, 640.0)
	_panel.custom_minimum_size = Vector2(w, h)


# ================================================================
# Open / close
# ================================================================
func open_browser(save_as_mode := false) -> void:
	_mode = Mode.BROWSE
	_expanded = ""
	_search.text = ""
	_name_form.visible = false
	visible = true
	_refresh()
	if save_as_mode:
		_save_as()


func close_browser() -> void:
	visible = false
	_name_form.visible = false


func is_open() -> bool:
	return visible


# ================================================================
# Top-level actions
# ================================================================
func quick_save() -> void:
	if current_path == "":
		open_browser(true)
		return
	var data := store.read_save(current_path)
	if data.is_empty():
		# file vanished or corrupted — recreate the wrapper in place
		data = store.make_save_data(current_name, {})
	data.current = Snapshot.capture(sim, rig)
	data.meta.modified_ms = SaveStore.now_ms()
	if store.write_save(current_path, data):
		Events.toast_requested.emit("Saved \"%s\"" % current_name)
	else:
		Events.toast_requested.emit("Couldn't write the save file")
	if visible:
		_refresh()


func _save_as() -> void:
	var initial := current_name if current_name != "" else "Experiment"
	_open_name_form("Save current state as…", initial, func(name: String) -> void:
		var path := store.create_save(_dir if _mode == Mode.BROWSE else "", name, Snapshot.capture(sim, rig))
		if path == "":
			Events.toast_requested.emit("Couldn't create the save")
			return
		current_path = path
		current_name = name
		Events.toast_requested.emit("Saved \"%s\"" % name)
		_refresh())


## action-row button: instant checkpoint with a default label (the sub-view
## has a labelled create for deliberate checkpoints)
func _quick_checkpoint() -> void:
	if current_path == "":
		Events.toast_requested.emit("No save loaded — use Save as… first")
		_save_as()
		return
	_create_checkpoint("")


func do_reset() -> void:
	ConfirmPanel.ask(self, "Reset the solar system?",
		"Removes every added body and restores the pristine planets at today's date. Your saves are not affected.",
		"Reset", true, func() -> void:
			Snapshot.apply(sim, rig, Snapshot.default_snapshot())
			Events.toast_requested.emit("Solar system reset")
			close_browser())


# ================================================================
# Refresh (breadcrumbs + list)
# ================================================================
func _refresh() -> void:
	_loaded_lbl.text = ("Loaded: %s" % current_name) if current_path != "" else "Nothing loaded"
	_quick_btn.disabled = current_path == ""
	_search.visible = _mode == Mode.BROWSE
	_rebuild_subhead()
	_rebuild_list()


func _rebuild_subhead() -> void:
	for c in _subhead.get_children():
		_subhead.remove_child(c)
		c.queue_free()
	match _mode:
		Mode.BROWSE, Mode.MOVE:
			if _mode == Mode.MOVE:
				var move_lbl := UITheme.make_label("Move \"%s\" to:" % _move_name, 11, UITheme.ACCENT_WARM)
				move_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				_subhead.add_child(move_lbl)
			_add_crumb("Saves", "")
			var parts := _dir.split("/", false)
			var acc := ""
			for part in parts:
				_subhead.add_child(UITheme.make_label("/", 11, UITheme.MUTED))
				acc = acc.path_join(part)
				_add_crumb(part, acc)
			var spacer := Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_subhead.add_child(spacer)
			if _mode == Mode.BROWSE:
				_subhead.add_child(_chip("New folder", func() -> void:
					_open_name_form("New folder in %s" % ("Saves" if _dir == "" else _dir), "Folder", func(name: String) -> void:
						if store.create_folder(_dir, name) == "":
							Events.toast_requested.emit("Couldn't create the folder")
						_refresh())))
			else:
				var here := Button.new()
				here.text = "Move here"
				UITheme.style_primary(here)
				here.pressed.connect(_move_confirm)
				_subhead.add_child(here)
				_subhead.add_child(_chip("Cancel", func() -> void:
					_mode = Mode.BROWSE
					_refresh()))
		Mode.CHECKPOINTS:
			_subhead.add_child(_chip("← Back", func() -> void:
				_mode = Mode.BROWSE
				_refresh()))
			var lbl := UITheme.make_label("Checkpoints · %s" % _cp_name, 12, UITheme.TEXT)
			lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_subhead.add_child(lbl)


func _rebuild_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	match _mode:
		Mode.BROWSE:
			if _search.text.strip_edges() != "":
				_build_search_results()
			else:
				_build_folder_view(true)
		Mode.MOVE:
			_build_folder_view(false)
		Mode.CHECKPOINTS:
			_build_checkpoint_view()


func _build_folder_view(with_saves: bool) -> void:
	var listing := store.list_dir(_dir)
	for folder in listing.folders:
		_list.add_child(_folder_row(folder))
	if with_saves:
		for e in listing.saves:
			_list.add_child(_save_row(e, false))
			if _expanded == e.path:
				_list.add_child(_save_actions(e))
	if _list.get_child_count() == 0:
		if _mode == Mode.MOVE:
			_empty_label("No folders here — use \"Move here\" or go back")
		elif _dir == "":
			_empty_label("No saves yet — use Save as… to keep this experiment")
		else:
			_empty_label("This folder is empty")


func _build_search_results() -> void:
	var hits := store.search(_search.text)
	for e in hits:
		_list.add_child(_save_row(e, true))
		if _expanded == e.path:
			_list.add_child(_save_actions(e))
	if hits.is_empty():
		_empty_label("No saves matching \"%s\"" % _search.text.strip_edges())


func _build_checkpoint_view() -> void:
	var data := store.read_save(_cp_path)
	if data.is_empty():
		_empty_label("Couldn't read this save")
		return
	if _cp_path == current_path:
		var create_row := HBoxContainer.new()
		create_row.add_theme_constant_override("separation", 8)
		var label_edit := LineEdit.new()
		label_edit.placeholder_text = "Checkpoint label (optional)"
		label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label_edit.custom_minimum_size = Vector2(0, 42) if UITheme.touch else Vector2(0, 30)
		label_edit.add_theme_font_size_override("font_size", UITheme.fs(12))
		create_row.add_child(label_edit)
		var create_btn := Button.new()
		create_btn.text = "Create checkpoint"
		UITheme.style_primary(create_btn)
		create_btn.pressed.connect(func() -> void:
			_create_checkpoint(label_edit.text.strip_edges())
			_refresh())
		create_row.add_child(create_btn)
		_list.add_child(create_row)

	var cps: Array = data.checkpoints
	for i in range(cps.size() - 1, -1, -1):   # newest first
		_list.add_child(_checkpoint_row(cps[i]))
	if cps.is_empty():
		if _cp_path == current_path:
			_empty_label("No checkpoints yet — create one to mark this moment")
		else:
			_empty_label("This save has no checkpoints")


# ================================================================
# Rows
# ================================================================
func _folder_row(folder: String) -> Control:
	var display := folder.get_file()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var main := _row_button("▸  " + display, "", UITheme.MUTED)
	main.pressed.connect(func() -> void:
		_dir = folder
		_expanded = ""
		_refresh())
	row.add_child(main)
	if _mode == Mode.BROWSE:
		var more := _more_button(folder)
		row.add_child(more)
	if _expanded == folder and _mode == Mode.BROWSE:
		var wrap := VBoxContainer.new()
		wrap.add_child(row)
		wrap.add_child(_folder_actions(folder, display))
		return wrap
	return row


func _save_row(e: Dictionary, show_folder: bool) -> Control:
	var subtitle := ""
	if bool(e.get("corrupt", false)):
		subtitle = "can't read this file"
	else:
		var n := int(e.checkpoint_count)
		var when: String = Fmt.fmt_date(float(e.modified_ms))[0]
		subtitle = when if n == 0 else "%s · %d checkpoint%s" % [when, n, "" if n == 1 else "s"]
		if show_folder and e.folder != "":
			subtitle += " · in %s/" % e.folder
	var is_loaded: bool = e.path == current_path
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var main := _row_button(e.name, subtitle, UITheme.TEXT)
	if is_loaded:
		main.add_theme_stylebox_override("normal",
			UITheme.flat_style(Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.13)))
	if bool(e.get("corrupt", false)):
		main.disabled = true
	main.pressed.connect(func() -> void: _confirm_load(e))
	row.add_child(main)
	row.add_child(_more_button(e.path))
	return row


func _checkpoint_row(cp: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var when: String = Fmt.fmt_date(float(cp.get("created_ms", 0.0)))[0]
	var main := _row_button(str(cp.get("label", "Checkpoint")), when, UITheme.TEXT)
	main.disabled = true   # tap actions live on the explicit buttons
	row.add_child(main)
	var restore := _chip("Restore", func() -> void:
		ConfirmPanel.ask(self, "Restore this checkpoint?",
			"The simulation jumps back to \"%s\". The save itself keeps its latest state until you quick-save." % str(cp.get("label", "Checkpoint")),
			"Restore", false, func() -> void:
				if Snapshot.apply(sim, rig, cp.get("snapshot", {})):
					Events.toast_requested.emit("Checkpoint restored — quick-save to keep it")
					close_browser()))
	row.add_child(restore)
	var del := _chip("Delete", func() -> void:
		ConfirmPanel.ask(self, "Delete this checkpoint?",
			"\"%s\" is removed from the history. This can't be undone." % str(cp.get("label", "Checkpoint")),
			"Delete", true, func() -> void:
				_delete_checkpoint(int(cp.get("id", -1)))))
	del.add_theme_color_override("font_color", Color("ff9d9d"))
	row.add_child(del)
	return row


## expanding action strip under a save row (no popup menus — poor on touch)
func _save_actions(e: Dictionary) -> Control:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 6)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(16, 0)
	strip.add_child(pad)
	if not bool(e.get("corrupt", false)):
		strip.add_child(_chip("Rename", func() -> void:
			_open_name_form("Rename \"%s\"" % e.name, e.name, func(name: String) -> void:
				var np := store.rename_save(e.path, name)
				if np == "":
					Events.toast_requested.emit("Couldn't rename the save")
				elif e.path == current_path:
					current_path = np
					current_name = name
				_expanded = ""
				_refresh())))
		strip.add_child(_chip("Duplicate", func() -> void:
			_open_name_form("Duplicate \"%s\" as…" % e.name, str(e.name) + " copy", func(name: String) -> void:
				_duplicate(e, name))))
		strip.add_child(_chip("Move", func() -> void:
			_mode = Mode.MOVE
			_move_path = e.path
			_move_name = e.name
			_expanded = ""
			_refresh()))
		strip.add_child(_chip("Checkpoints", func() -> void:
			_mode = Mode.CHECKPOINTS
			_cp_path = e.path
			_cp_name = e.name
			_expanded = ""
			_refresh()))
	var del := _chip("Delete", func() -> void:
		ConfirmPanel.ask(self, "Delete \"%s\"?" % e.name,
			"The save and all its checkpoints are removed. This can't be undone.",
			"Delete", true, func() -> void:
				if store.delete_save(e.path):
					if e.path == current_path:
						current_path = ""
						current_name = ""
					Events.toast_requested.emit("Deleted \"%s\"" % e.name)
				_expanded = ""
				_refresh()))
	del.add_theme_color_override("font_color", Color("ff9d9d"))
	strip.add_child(del)
	return strip


func _folder_actions(folder: String, display: String) -> Control:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 6)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(16, 0)
	strip.add_child(pad)
	strip.add_child(_chip("Rename", func() -> void:
		_open_name_form("Rename folder \"%s\"" % display, display, func(name: String) -> void:
			var np := store.rename_folder(folder, name)
			if np == "":
				Events.toast_requested.emit("Couldn't rename the folder")
			elif current_path.begins_with(folder + "/"):
				current_path = np + current_path.trim_prefix(folder)
			_expanded = ""
			_refresh())))
	var del := _chip("Delete", func() -> void:
		ConfirmPanel.ask(self, "Delete folder \"%s\"?" % display,
			"Every save and subfolder inside is removed. This can't be undone.",
			"Delete all", true, func() -> void:
				if store.delete_folder(folder):
					if current_path.begins_with(folder + "/"):
						current_path = ""
						current_name = ""
					Events.toast_requested.emit("Deleted folder \"%s\"" % display)
				_expanded = ""
				_refresh()))
	del.add_theme_color_override("font_color", Color("ff9d9d"))
	strip.add_child(del)
	return strip


# ================================================================
# Operations
# ================================================================
func _confirm_load(e: Dictionary) -> void:
	if bool(e.get("corrupt", false)):
		return
	ConfirmPanel.ask(self, "Load \"%s\"?" % e.name,
		"The current simulation state is replaced. Quick-save first if you want to keep it.",
		"Load", false, func() -> void:
			var data := store.read_save(e.path)
			if data.is_empty():
				Events.toast_requested.emit("Couldn't read the save file")
				return
			if Snapshot.apply(sim, rig, data.current):
				current_path = e.path
				current_name = e.name
				Events.toast_requested.emit("Loaded \"%s\"" % e.name)
				close_browser())


## duplicate = branch: the loaded save is committed first, then the copy
## becomes the loaded save (per the branch workflow)
func _duplicate(e: Dictionary, name: String) -> void:
	if e.path == current_path:
		quick_save()
	var np := store.duplicate_save(e.path, name)
	if np == "":
		Events.toast_requested.emit("Couldn't duplicate the save")
	else:
		if e.path == current_path:
			current_path = np
			current_name = name
			Events.toast_requested.emit("Branched to \"%s\"" % name)
		else:
			Events.toast_requested.emit("Duplicated as \"%s\"" % name)
	_expanded = ""
	_refresh()


func _move_confirm() -> void:
	var np := store.move_save(_move_path, _dir)
	if np == "":
		Events.toast_requested.emit("Couldn't move the save")
	else:
		if _move_path == current_path:
			current_path = np
		Events.toast_requested.emit("Moved \"%s\"" % _move_name)
	_mode = Mode.BROWSE
	_refresh()


func _create_checkpoint(label: String) -> void:
	var data := store.read_save(current_path)
	if data.is_empty():
		Events.toast_requested.emit("Couldn't read the save file")
		return
	var snap := Snapshot.capture(sim, rig)
	var id := int(data.get("next_checkpoint_id", 1))
	data.current = snap
	data.checkpoints.append({
		id = id,
		label = label if label != "" else "At " + Fmt.fmt_date(sim.sim_ms)[0],
		created_ms = SaveStore.now_ms(),
		snapshot = snap,
	})
	data.next_checkpoint_id = id + 1
	data.meta.modified_ms = SaveStore.now_ms()
	if store.write_save(current_path, data):
		Events.toast_requested.emit("Checkpoint saved to \"%s\"" % current_name)
	else:
		Events.toast_requested.emit("Couldn't write the save file")


func _delete_checkpoint(id: int) -> void:
	var data := store.read_save(_cp_path)
	if data.is_empty():
		return
	var kept: Array = []
	for cp in data.checkpoints:
		if int(cp.get("id", -1)) != id:
			kept.append(cp)
	data.checkpoints = kept
	data.meta.modified_ms = SaveStore.now_ms()
	store.write_save(_cp_path, data)
	_refresh()


# ================================================================
# Widget helpers
# ================================================================
func _action_btn(parent: Control, text: String, styler: Callable, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	styler.call(b)
	if UITheme.touch:
		b.custom_minimum_size = Vector2(0, 46)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _chip(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	UITheme.style_chip(b, 11)
	b.add_theme_stylebox_override("normal", UITheme.flat_style(Color(1, 1, 1, 0.06)))
	if UITheme.touch:
		b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(action)
	return b


## two-line list row (title + muted subtitle), rail-item style
func _row_button(title: String, subtitle: String, title_color: Color) -> Button:
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := 56.0 if UITheme.touch else 44.0
	if subtitle == "":
		h = 48.0 if UITheme.touch else 36.0
	btn.custom_minimum_size = Vector2(0, h)
	btn.add_theme_stylebox_override("normal", UITheme.flat_style(Color(0, 0, 0, 0)))
	btn.add_theme_stylebox_override("hover", UITheme.flat_style(Color(1, 1, 1, 0.06)))
	btn.add_theme_stylebox_override("pressed", UITheme.flat_style(Color(1, 1, 1, 0.08)))
	btn.add_theme_stylebox_override("disabled", UITheme.flat_style(Color(0, 0, 0, 0)))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 10
	col.offset_right = -10
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var t := UITheme.make_label(title, 13, title_color)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(t)
	if subtitle != "":
		var s := UITheme.make_label(subtitle, 10, UITheme.MUTED)
		s.mouse_filter = Control.MOUSE_FILTER_IGNORE
		s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(s)
	btn.add_child(col)
	return btn


func _more_button(path: String) -> Button:
	var b := Button.new()
	b.text = "⋯"
	UITheme.style_chip(b, 14)
	b.custom_minimum_size = Vector2(48, 0) if UITheme.touch else Vector2(36, 0)
	b.pressed.connect(func() -> void:
		_expanded = "" if _expanded == path else path
		_refresh())
	return b


func _add_crumb(text: String, dir: String) -> void:
	var b := _chip(text, func() -> void:
		_dir = dir
		_expanded = ""
		_refresh())
	if dir == _dir:
		UITheme.set_chip_active(b, true)
	_subhead.add_child(b)


func _empty_label(text: String) -> void:
	var l := UITheme.make_label(text, 11, UITheme.MUTED)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 24)
	_list.add_child(pad)
	_list.add_child(l)


func _open_name_form(title: String, initial: String, cb: Callable) -> void:
	_name_title.text = title
	_name_edit.text = initial
	_name_cb = cb
	_name_form.visible = true
	_name_edit.grab_focus()
	_name_edit.select_all()


func _name_form_ok() -> void:
	var name := _name_edit.text.strip_edges()
	if name == "":
		return
	_name_form.visible = false
	if _name_cb.is_valid():
		_name_cb.call(name)
