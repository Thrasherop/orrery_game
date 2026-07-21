class_name ToastLabel
extends PanelContainer
## Top-center toast for merge announcements. Fades in, lingers 3.4 s, fades out.

var _label: Label
var _tween: Tween = null
var _timer: SceneTreeTimer = null


func _init() -> void:
	add_theme_stylebox_override("panel", UITheme.panel_style(11, 14))
	_label = UITheme.make_label("", 12, UITheme.TEXT)
	add_child(_label)
	modulate.a = 0.0
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	Events.toast_requested.connect(show_toast)


func show_toast(msg: String) -> void:
	_label.text = msg
	visible = true
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "modulate:a", 1.0, 0.3)
	_tween.tween_interval(3.4)
	_tween.tween_property(self, "modulate:a", 0.0, 0.3)
	_tween.tween_callback(func() -> void: visible = false)
