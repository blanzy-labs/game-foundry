class_name CyberShieldGame
extends Node2D

const ThreatLabels = preload("res://threat_labels.gd")

const GAME_ID := "cyber-shield"
const TITLE := "CYBER SHIELD"
const PLAYING := "PLAYING"
const GAME_OVER := "GAME_OVER"
const BLOCKED := "BLOCKED"
const MISSED := "MISSED"
const WIDTH := 960.0
const HEIGHT := 540.0
const PLAY_LEFT := 34.0
const PLAY_RIGHT := 926.0
const SPAWN_TOP := 76.0
const BOTTOM_BOUNDARY := 540.0
const PADDLE_SIZE := Vector2(190.0, 22.0)
const PADDLE_Y := 474.0
const PADDLE_SPEED := 560.0
const MOUSE_SPEED := 1400.0
const THREAT_SIZE := Vector2(138.0, 42.0)
const FALL_SPEED := 132.0
const SPAWN_INTERVAL := 1.15
const MAX_BREACHES := 3

var state := PLAYING
var score := 0
var breaches := 0
var paddle_x := (WIDTH - PADDLE_SIZE.x) * 0.5
var threats: Array[Dictionary] = []
var resolved_outcomes: Dictionary = {}
var next_threat_id := 1
var spawn_elapsed := 0.0
var spawn_count := 0
var keyboard_received := false
var mouse_received := false
var touch_received := false
var mouse_target_x := -1.0
var test_mode := false
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	test_mode = _web_test_mode_enabled()
	restart_game()
	print("CYBER_SHIELD_RUNTIME_READY")
	if OS.get_cmdline_user_args().has("--runtime-smoke"):
		print("CYBER_SHIELD_RUNTIME_SMOKE_OK")
		get_tree().quit(0)
		return
	_publish_web_state(true)
	queue_redraw()


func _physics_process(delta: float) -> void:
	var changed := false
	if state == PLAYING:
		var axis := 0.0
		if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
			axis -= 1.0
		if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
			axis += 1.0
		if axis != 0.0:
			changed = _move_paddle(axis, delta) or changed
		elif mouse_target_x >= 0.0:
			var old_x := paddle_x
			paddle_x = clampf(move_toward(paddle_x, mouse_target_x - PADDLE_SIZE.x * 0.5, MOUSE_SPEED * delta), PLAY_LEFT, PLAY_RIGHT - PADDLE_SIZE.x)
			changed = not is_equal_approx(old_x, paddle_x) or changed
	changed = _advance_gameplay(delta) or changed
	if changed:
		_publish_web_state(false)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		keyboard_received = true
		if event.keycode == KEY_R and state == GAME_OVER:
			restart_game()
		elif test_mode and state == PLAYING and event.keycode == KEY_B:
			_force_block_threat()
		elif test_mode and state == PLAYING and event.keycode == KEY_M:
			_force_missed_threat()
		elif test_mode and state == PLAYING and event.keycode == KEY_S:
			_spawn_threat()
		_publish_web_state(false)
	elif event is InputEventMouseMotion:
		mouse_received = true
		mouse_target_x = event.position.x
		_publish_web_state(false)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		mouse_received = true
		mouse_target_x = event.position.x
		_publish_web_state(false)
	elif event is InputEventScreenTouch and event.pressed:
		touch_received = true
		mouse_target_x = event.position.x
		_publish_web_state(false)
	elif event is InputEventScreenDrag:
		touch_received = true
		mouse_target_x = event.position.x
		_publish_web_state(false)


func restart_game() -> void:
	state = PLAYING
	score = 0
	breaches = 0
	paddle_x = (WIDTH - PADDLE_SIZE.x) * 0.5
	threats.clear()
	resolved_outcomes.clear()
	next_threat_id = 1
	spawn_elapsed = 0.0
	spawn_count = 0
	mouse_target_x = -1.0
	_publish_web_state(false)
	queue_redraw()


func _move_paddle(direction: float, delta: float) -> bool:
	var old_x := paddle_x
	paddle_x = clampf(paddle_x + direction * PADDLE_SPEED * delta, PLAY_LEFT, PLAY_RIGHT - PADDLE_SIZE.x)
	return not is_equal_approx(old_x, paddle_x)


func _advance_gameplay(delta: float) -> bool:
	if state != PLAYING:
		return false
	var changed := false
	if not test_mode:
		spawn_elapsed += delta
		while spawn_elapsed >= SPAWN_INTERVAL and state == PLAYING:
			spawn_elapsed -= SPAWN_INTERVAL
			_spawn_threat()
			changed = true
	var terminal_events: Array[Dictionary] = []
	var paddle := paddle_rect()
	for threat in threats:
		var position: Vector2 = threat.position
		position.y += FALL_SPEED * delta
		threat.position = position
		var rectangle := Rect2(position, THREAT_SIZE)
		if rectangle.intersects(paddle):
			terminal_events.append({"id": threat.id, "outcome": BLOCKED})
		elif position.y > BOTTOM_BOUNDARY:
			terminal_events.append({"id": threat.id, "outcome": MISSED})
	for event in terminal_events:
		changed = _resolve_threat(event.id, event.outcome) or changed
	if not threats.is_empty():
		changed = true
	return changed


func _spawn_threat() -> int:
	if state != PLAYING:
		return -1
	var x := rng.randf_range(PLAY_LEFT, PLAY_RIGHT - THREAT_SIZE.x)
	var label := ThreatLabels.LABELS[rng.randi_range(0, ThreatLabels.LABELS.size() - 1)]
	return _add_threat(Vector2(x, SPAWN_TOP), label)


func _add_threat(position: Vector2, label: String) -> int:
	if state != PLAYING:
		return -1
	var threat_id := next_threat_id
	next_threat_id += 1
	spawn_count += 1
	threats.append({"id": threat_id, "label": label, "position": position})
	return threat_id


func _resolve_threat(threat_id: int, outcome: String) -> bool:
	if state != PLAYING or resolved_outcomes.has(threat_id) or outcome not in [BLOCKED, MISSED]:
		return false
	var found_index := -1
	for index in threats.size():
		if threats[index].id == threat_id:
			found_index = index
			break
	if found_index < 0:
		return false
	resolved_outcomes[threat_id] = outcome
	threats.remove_at(found_index)
	if outcome == BLOCKED:
		score += 1
	else:
		breaches += 1
		if breaches >= MAX_BREACHES:
			breaches = MAX_BREACHES
			state = GAME_OVER
			threats.clear()
			spawn_elapsed = 0.0
	_publish_web_state(false)
	return true


func _force_block_threat() -> int:
	var paddle := paddle_rect()
	var threat_id := _add_threat(Vector2(paddle.position.x + 18.0, paddle.position.y), "PHISHING")
	_advance_gameplay(0.0)
	return threat_id


func _force_missed_threat() -> int:
	var threat_id := _add_threat(Vector2(PLAY_LEFT, BOTTOM_BOUNDARY + 1.0), "MALWARE")
	_advance_gameplay(0.0)
	return threat_id


func paddle_rect() -> Rect2:
	return Rect2(Vector2(paddle_x, PADDLE_Y), PADDLE_SIZE)


func snapshot() -> Dictionary:
	var threat_snapshots: Array[Dictionary] = []
	for threat in threats:
		threat_snapshots.append({
			"id": threat.id,
			"label": threat.label,
			"x": snappedf(threat.position.x, 0.001),
			"y": snappedf(threat.position.y, 0.001),
		})
	return {
		"game_id": GAME_ID,
		"title": TITLE,
		"state": state,
		"score": score,
		"breaches": breaches,
		"max_breaches": MAX_BREACHES,
		"paddle_x": snappedf(paddle_x, 0.001),
		"paddle_left": snappedf(paddle_rect().position.x, 0.001),
		"paddle_right": snappedf(paddle_rect().end.x, 0.001),
		"active_threats": threats.size(),
		"threats": threat_snapshots,
		"spawn_count": spawn_count,
		"keyboard_received": keyboard_received,
		"mouse_received": mouse_received,
		"touch_received": touch_received,
		"test_mode": test_mode,
	}


func reset_for_test(seed_value: int = 4242) -> void:
	rng.seed = seed_value
	restart_game()


func move_paddle_for_test(direction: float, delta: float) -> bool:
	return _move_paddle(direction, delta)


func spawn_sample_for_test() -> Rect2:
	var threat_id := _spawn_threat()
	for threat in threats:
		if threat.id == threat_id:
			return Rect2(threat.position, THREAT_SIZE)
	return Rect2()


func clear_threats_for_test() -> void:
	threats.clear()


func force_block_for_test() -> int:
	return _force_block_threat()


func force_miss_for_test() -> int:
	return _force_missed_threat()


func resolve_again_for_test(threat_id: int, outcome: String) -> bool:
	return _resolve_threat(threat_id, outcome)


func advance_for_test(delta: float) -> void:
	_advance_gameplay(delta)


func outcome_for_test(threat_id: int) -> String:
	return str(resolved_outcomes.get(threat_id, ""))


func _web_test_mode_enabled() -> bool:
	if not OS.has_feature("web"):
		return false
	return bool(JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('gf_test') === '1'", true))


func _publish_web_state(ready: bool) -> void:
	if not OS.has_feature("web"):
		return
	var generic_state := "INPUT_RECEIVED" if keyboard_received else state
	var script := "window.GF_WEB_RUNTIME_READY=%s;window.GF_WEB_RUNTIME_STATE=%s;window.GF_WEB_KEYBOARD_RECEIVED=%s;window.GF_WEB_MOUSE_RECEIVED=%s;window.CYBER_SHIELD_STATE=%s;" % [
		"true" if ready else "window.GF_WEB_RUNTIME_READY===true",
		JSON.stringify(generic_state),
		"true" if keyboard_received else "false",
		"true" if mouse_received else "false",
		JSON.stringify(snapshot()),
	]
	JavaScriptBridge.eval(script, true)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(0, 0, WIDTH, HEIGHT), Color("061126"))
	for x in range(0, int(WIDTH), 48):
		draw_line(Vector2(x, 62), Vector2(x, HEIGHT), Color(0.07, 0.23, 0.34, 0.24), 1.0)
	for y in range(62, int(HEIGHT), 48):
		draw_line(Vector2(0, y), Vector2(WIDTH, y), Color(0.07, 0.23, 0.34, 0.24), 1.0)
	draw_rect(Rect2(20, 18, WIDTH - 40, HEIGHT - 36), Color("18d6c3"), false, 2.0)
	draw_string(font, Vector2(34, 48), TITLE, HORIZONTAL_ALIGNMENT_LEFT, -1, 27, Color("52f3df"))
	draw_string(font, Vector2(618, 45), "SCORE: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 21, Color("f5fbff"))
	draw_string(font, Vector2(790, 45), "BREACHES: %d / %d" % [breaches, MAX_BREACHES], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("ff8b8b"))
	draw_line(Vector2(PLAY_LEFT, 516), Vector2(PLAY_RIGHT, 516), Color("295170"), 2.0)
	for threat in threats:
		_draw_threat(font, threat)
	var paddle := paddle_rect()
	draw_rect(Rect2(paddle.position - Vector2(5, 5), paddle.size + Vector2(10, 10)), Color(0.11, 0.91, 0.80, 0.2))
	draw_rect(paddle, Color("35e8d1"))
	draw_rect(Rect2(paddle.position + Vector2(9, 6), Vector2(paddle.size.x - 18, 5)), Color("d9fffa"))
	var shield_text := "CYBER SHIELD"
	var shield_width := font.get_string_size(shield_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	draw_string(font, Vector2(paddle.position.x + (paddle.size.x - shield_width) * 0.5, paddle.position.y - 10), shield_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("aafff4"))
	if state == GAME_OVER:
		draw_rect(Rect2(190, 150, 580, 244), Color(0.012, 0.027, 0.059, 0.96))
		draw_rect(Rect2(190, 150, 580, 244), Color("ff647c"), false, 3.0)
		_draw_centered(font, "GAME OVER", 217, 46, Color("ff647c"))
		_draw_centered(font, "ATTACKS BLOCKED: %d" % score, 277, 25, Color("f5fbff"))
		_draw_centered(font, "3 BREACHES DETECTED", 319, 19, Color("ffb1bd"))
		_draw_centered(font, "R  —  RESTART", 363, 21, Color("52f3df"))
	else:
		draw_string(font, Vector2(34, 528), "MOVE: LEFT / RIGHT  |  A / D  |  MOUSE  |  TOUCH", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("8eb7cc"))


func _draw_threat(font: Font, threat: Dictionary) -> void:
	var rectangle := Rect2(threat.position, THREAT_SIZE)
	draw_rect(Rect2(rectangle.position - Vector2(3, 3), rectangle.size + Vector2(6, 6)), Color(1.0, 0.28, 0.39, 0.2))
	draw_rect(rectangle, Color("d93656"))
	draw_rect(rectangle, Color("ff8296"), false, 2.0)
	var label := str(threat.label)
	var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_string(font, Vector2(rectangle.position.x + (rectangle.size.x - label_width) * 0.5, rectangle.position.y + 27), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("ffffff"))


func _draw_centered(font: Font, text: String, baseline_y: float, font_size: int, color: Color) -> void:
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2((WIDTH - text_width) * 0.5, baseline_y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
