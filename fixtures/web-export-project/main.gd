extends Node2D

const WEB_EXPORT_MARKER := "GAME_FOUNDRY_WEB_EXPORT_FIXTURE_OK"

var runtime_state := "IDLE"
var keyboard_received := false
var mouse_received := false


func _ready() -> void:
	print(WEB_EXPORT_MARKER)
	_publish_runtime_state(true)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		keyboard_received = true
		runtime_state = "INPUT_RECEIVED"
		_publish_runtime_state(false)
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		mouse_received = true
		_publish_runtime_state(false)
		queue_redraw()


func _publish_runtime_state(ready: bool) -> void:
	if not OS.has_feature("web"):
		return
	var script := "window.GF_WEB_RUNTIME_READY=%s;window.GF_WEB_RUNTIME_STATE=%s;window.GF_WEB_KEYBOARD_RECEIVED=%s;window.GF_WEB_MOUSE_RECEIVED=%s;" % [
		"true" if ready else "window.GF_WEB_RUNTIME_READY===true",
		JSON.stringify(runtime_state),
		"true" if keyboard_received else "false",
		"true" if mouse_received else "false",
	]
	JavaScriptBridge.eval(script, true)


func _draw() -> void:
	var background := Color("123d2f") if keyboard_received else Color("07132a")
	var body := Color("f72585") if mouse_received else Color("4cc9f0")
	draw_rect(Rect2(0, 0, 640, 360), background)
	draw_circle(Vector2(320, 165), 72, body)
	draw_circle(Vector2(295, 150), 9, Color("07132a"))
	draw_circle(Vector2(345, 150), 9, Color("07132a"))
	draw_arc(Vector2(320, 175), 28, 0.2, PI - 0.2, 32, Color("07132a"), 6)
