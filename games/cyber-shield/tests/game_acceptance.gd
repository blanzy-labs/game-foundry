extends SceneTree

const Game = preload("res://cyber_shield.gd")

var checks: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _record(name: String, passed: bool, detail: Dictionary = {}) -> void:
	checks.append({"name": name, "status": "pass" if passed else "fail", "detail": detail})
	print("%-32s %s" % [name, "PASS" if passed else "FAIL"])


func _run() -> void:
	var game := Game.new()
	root.add_child(game)
	await process_frame
	game.set_physics_process(false)
	game.reset_for_test(4242)

	var initial := game.snapshot()
	_record("initial_state", initial.score == 0 and initial.breaches == 0 and initial.state == game.PLAYING, initial)

	var start_x: float = initial.paddle_x
	game.move_paddle_for_test(-1.0, 0.1)
	var moved_left := game.snapshot()
	_record("paddle_movement", moved_left.paddle_x < start_x, {"before": start_x, "after": moved_left.paddle_x})
	game.move_paddle_for_test(-1.0, 100.0)
	var left_bound := game.snapshot()
	game.move_paddle_for_test(1.0, 100.0)
	var right_bound := game.snapshot()
	_record("paddle_bounds", left_bound.paddle_left >= game.PLAY_LEFT and right_bound.paddle_right <= game.PLAY_RIGHT, {"left": left_bound, "right": right_bound})

	game.reset_for_test(9001)
	var spawn_bounds_pass := true
	var spawn_samples: Array[Dictionary] = []
	for sample_index in 100:
		var rectangle := game.spawn_sample_for_test()
		var inside := rectangle.position.x >= game.PLAY_LEFT and rectangle.end.x <= game.PLAY_RIGHT and is_equal_approx(rectangle.position.y, game.SPAWN_TOP)
		spawn_bounds_pass = spawn_bounds_pass and inside
		spawn_samples.append({"x": snappedf(rectangle.position.x, 0.001), "right": snappedf(rectangle.end.x, 0.001), "y": rectangle.position.y})
		game.clear_threats_for_test()
	_record("spawn_bounds_100_samples", spawn_bounds_pass, {"samples": spawn_samples})

	game.reset_for_test(4242)
	var first_block_id := game.force_block_for_test()
	var first_block := game.snapshot()
	_record("blocked_threat", first_block.score == 1 and first_block.breaches == 0 and game.outcome_for_test(first_block_id) == game.BLOCKED, first_block)
	var duplicate_changed := game.resolve_again_for_test(first_block_id, game.MISSED)
	var after_duplicate := game.snapshot()
	_record("duplicate_event_protection", not duplicate_changed and after_duplicate.score == 1 and after_duplicate.breaches == 0, after_duplicate)

	game.force_block_for_test()
	var second_block := game.snapshot()
	_record("second_blocked_threat", second_block.score == 2 and second_block.breaches == 0, second_block)

	var first_miss_id := game.force_miss_for_test()
	var first_miss := game.snapshot()
	_record("missed_threat", first_miss.score == 2 and first_miss.breaches == 1 and game.outcome_for_test(first_miss_id) == game.MISSED, first_miss)
	game.force_miss_for_test()
	game.force_miss_for_test()
	var game_over := game.snapshot()
	_record("three_breach_game_over", game_over.breaches == 3 and game_over.state == game.GAME_OVER and game_over.active_threats == 0, game_over)

	var spawn_count_at_game_over: int = game_over.spawn_count
	game.advance_for_test(game.SPAWN_INTERVAL * 5.0)
	var stopped := game.snapshot()
	_record("spawn_stops_at_game_over", stopped.spawn_count == spawn_count_at_game_over and stopped.active_threats == 0, stopped)

	game.restart_game()
	var restarted := game.snapshot()
	_record("restart_clean_state", restarted.score == 0 and restarted.breaches == 0 and restarted.state == game.PLAYING and restarted.active_threats == 0 and restarted.spawn_count == 0, restarted)

	var failures := checks.filter(func(check: Dictionary) -> bool: return check.status != "pass").size()
	var result := {
		"slice": "GF-WEB-004",
		"game_id": game.GAME_ID,
		"status": "pass" if failures == 0 else "fail",
		"checks": checks,
		"failures": failures,
		"threat_labels": Game.ThreatLabels.LABELS,
		"duplicate_terminal_outcomes_per_threat": 1,
	}
	print("GF_WEB_004_GAME_ACCEPTANCE=%s" % JSON.stringify(result))
	game.queue_free()
	quit(0 if failures == 0 else 1)
