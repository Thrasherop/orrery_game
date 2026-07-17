class_name SaveStore
extends RefCounted
## Filesystem CRUD for saved experiments. No UI or sim knowledge.
##
## Layout: user://saves/<folders...>/<slug>.save.json — folders are real
## directories (rename/move/delete stay single-source-of-truth), one JSON
## file per save holding meta + current snapshot + checkpoint history.
## The display name lives in meta.name; the filename is a slug of it.
##
## All `dir`/`path` arguments are RELATIVE to user://saves ("" = root),
## e.g. "rogue-star/close-flyby.save.json".
##
## Writes are atomic (tmp + rename) so a crash can't truncate a save.
## On web, user:// is IndexedDB-backed and flushes shortly after the file
## closes — a tab killed within ~1 s of saving may lose that write.

const ROOT := "user://saves"
const EXT := ".save.json"
const VERSION := 2   # v2 adds simulated moons (snapshot.moons + sim flags)


static func now_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0


func _abs(rel: String) -> String:
	return ROOT if rel == "" else ROOT.path_join(rel)


func _ensure_root() -> void:
	DirAccess.make_dir_recursive_absolute(ROOT)


# ================================================================
# Names
# ================================================================
## filename-safe slug of a display name (display name itself lives in meta)
func slugify(display_name: String) -> String:
	var out := ""
	for ch in display_name.strip_edges().to_lower():
		var is_alnum: bool = (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9")
		out += ch if is_alnum else "-"
	while out.contains("--"):
		out = out.replace("--", "-")
	out = out.trim_prefix("-").trim_suffix("-")
	return out if out != "" else "save"


## folder names ARE their display names — strip only what filesystems reject
func sanitize_folder_name(name: String) -> String:
	var out := ""
	for ch in name.strip_edges():
		if not "\\/:*?\"<>|".contains(ch):
			out += ch
	out = out.trim_suffix(".").strip_edges()
	return out if out != "" else "folder"


## first non-colliding "<slug>[-N].save.json" inside dir; returns a rel path
func unique_path(dir: String, slug: String) -> String:
	var candidate := slug
	var n := 2
	while FileAccess.file_exists(_abs(dir.path_join(candidate + EXT))):
		candidate = "%s-%d" % [slug, n]
		n += 1
	return dir.path_join(candidate + EXT)


func _unique_folder(dir: String, name: String) -> String:
	var candidate := name
	var n := 2
	while DirAccess.dir_exists_absolute(_abs(dir.path_join(candidate))):
		candidate = "%s %d" % [name, n]
		n += 1
	return dir.path_join(candidate)


# ================================================================
# Read / write
# ================================================================
func read_save(path: String) -> Dictionary:
	var abs := _abs(path)
	if not FileAccess.file_exists(abs):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(abs))
	return parsed if _valid_wrapper(parsed) else {}


func write_save(path: String, data: Dictionary) -> bool:
	_ensure_root()
	var abs := _abs(path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var tmp := abs + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	# full_precision: sim_ms and the N-body state need all float64 digits
	f.store_string(JSON.stringify(data, "", false, true))
	f.close()
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)   # rename-over-existing fails on Windows
	return DirAccess.rename_absolute(tmp, abs) == OK


func _valid_wrapper(d) -> bool:
	if typeof(d) != TYPE_DICTIONARY:
		return false
	var v := int(d.get("version", 0))
	if v < 1 or v > VERSION:
		return false
	if typeof(d.get("meta")) != TYPE_DICTIONARY or not d.meta.has("name"):
		return false
	if typeof(d.get("checkpoints", [])) != TYPE_ARRAY:
		return false
	return Snapshot.validate(d.get("current"))


func make_save_data(display_name: String, snapshot: Dictionary) -> Dictionary:
	var now := now_ms()
	return {
		version = VERSION,
		meta = { name = display_name.strip_edges(), created_ms = now, modified_ms = now },
		current = snapshot,
		checkpoints = [],
		next_checkpoint_id = 1,
	}


# ================================================================
# Save CRUD
# ================================================================
## returns the new save's rel path, or "" on failure
func create_save(dir: String, display_name: String, snapshot: Dictionary) -> String:
	var path := unique_path(dir, slugify(display_name))
	return path if write_save(path, make_save_data(display_name, snapshot)) else ""


func delete_save(path: String) -> bool:
	return DirAccess.remove_absolute(_abs(path)) == OK


## renames the display name and re-slugs the file; returns the (possibly
## unchanged) rel path, or "" on failure
func rename_save(path: String, new_name: String) -> String:
	var data := read_save(path)
	if data.is_empty():
		return ""
	data.meta.name = new_name.strip_edges()
	data.meta.modified_ms = now_ms()
	var dir := path.get_base_dir()
	var slug := slugify(new_name)
	var new_path := path
	if path.get_file() != slug + EXT:
		new_path = unique_path(dir, slug)
	if not write_save(new_path, data):
		return ""
	if new_path != path:
		DirAccess.remove_absolute(_abs(path))
	return new_path


## returns the save's new rel path, or "" on failure
func move_save(path: String, dest_dir: String) -> String:
	if path.get_base_dir() == dest_dir:
		return path
	var slug := path.get_file().trim_suffix(EXT)
	var new_path := unique_path(dest_dir, slug)
	DirAccess.make_dir_recursive_absolute(_abs(dest_dir))
	return new_path if DirAccess.rename_absolute(_abs(path), _abs(new_path)) == OK else ""


## copy under a new name (fresh created_ms, checkpoints travel along);
## returns the copy's rel path, or "" on failure
func duplicate_save(path: String, new_name: String) -> String:
	var data := read_save(path)
	if data.is_empty():
		return ""
	data.meta.name = new_name.strip_edges()
	data.meta.created_ms = now_ms()
	data.meta.modified_ms = data.meta.created_ms
	var new_path := unique_path(path.get_base_dir(), slugify(new_name))
	return new_path if write_save(new_path, data) else ""


# ================================================================
# Folder CRUD
# ================================================================
## returns the new folder's rel path, or "" on failure
func create_folder(dir: String, name: String) -> String:
	_ensure_root()
	var path := _unique_folder(dir, sanitize_folder_name(name))
	return path if DirAccess.make_dir_recursive_absolute(_abs(path)) == OK else ""


func rename_folder(path: String, new_name: String) -> String:
	var new_path := _unique_folder(path.get_base_dir(), sanitize_folder_name(new_name))
	return new_path if DirAccess.rename_absolute(_abs(path), _abs(new_path)) == OK else ""


func delete_folder(path: String) -> bool:
	return _delete_recursive(_abs(path))


func _delete_recursive(abs: String) -> bool:
	var d := DirAccess.open(abs)
	if d == null:
		return false
	for sub in d.get_directories():
		if not _delete_recursive(abs.path_join(sub)):
			return false
	for f in d.get_files():
		DirAccess.remove_absolute(abs.path_join(f))
	return DirAccess.remove_absolute(abs) == OK


# ================================================================
# Listing / search
# ================================================================
## { folders: [rel path], saves: [{path, name, modified_ms, checkpoint_count}] }
## folders alphabetical, saves most recently modified first
func list_dir(dir: String) -> Dictionary:
	_ensure_root()
	var out := { folders = [], saves = [] }
	var d := DirAccess.open(_abs(dir))
	if d == null:
		return out
	var folders := Array(d.get_directories())
	folders.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for sub in folders:
		out.folders.append(dir.path_join(sub))
	for f in d.get_files():
		if not f.ends_with(EXT):
			if f.ends_with(".tmp"):
				DirAccess.remove_absolute(_abs(dir.path_join(f)))   # stale crash leftover
			continue
		var entry := _entry_for(dir.path_join(f))
		if not entry.is_empty():
			out.saves.append(entry)
	out.saves.sort_custom(func(a, b) -> bool: return a.modified_ms > b.modified_ms)
	return out


## case-insensitive substring match on display names, across all folders;
## most recently modified first
func search(query: String) -> Array:
	var q := query.strip_edges().to_lower()
	var out: Array = []
	_search_walk("", q, out)
	out.sort_custom(func(a, b) -> bool: return a.modified_ms > b.modified_ms)
	return out


func _search_walk(dir: String, q: String, out: Array) -> void:
	var listing := list_dir(dir)
	for e in listing.saves:
		if q == "" or String(e.name).to_lower().contains(q):
			out.append(e)
	for sub in listing.folders:
		_search_walk(sub, q, out)


## listing entry for one save file ({} if unreadable/corrupt)
func _entry_for(path: String) -> Dictionary:
	var data := read_save(path)
	if data.is_empty():
		# still list it (as its filename) so the user can delete it
		return {
			path = path, name = path.get_file().trim_suffix(EXT),
			modified_ms = 0.0, checkpoint_count = 0, corrupt = true,
			folder = path.get_base_dir(),
		}
	return {
		path = path,
		name = data.meta.name,
		modified_ms = float(data.meta.get("modified_ms", 0.0)),
		checkpoint_count = (data.checkpoints as Array).size(),
		corrupt = false,
		folder = path.get_base_dir(),
	}
