class_name Prefs
## Tiny global (cross-save) preference store over user://settings.cfg.
## Per-save state belongs in Snapshot; only defaults for NEW saves live here.

const PATH := "user://settings.cfg"


static func moons_default() -> bool:
	return bool(_read("moons", "default_on", true))


static func set_moons_default(on: bool) -> void:
	_write("moons", "default_on", on)


static func _read(section: String, key: String, fallback):
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return fallback
	return cf.get_value(section, key, fallback)


static func _write(section: String, key: String, value) -> void:
	var cf := ConfigFile.new()
	cf.load(PATH)   # best-effort: keep other keys if the file exists
	cf.set_value(section, key, value)
	cf.save(PATH)
