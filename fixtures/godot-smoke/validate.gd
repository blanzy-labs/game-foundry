extends SceneTree

const Target = preload("res://automation_target.gd")

func _initialize() -> void:
	var expected := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--expected-token="):
			expected = argument.trim_prefix("--expected-token=")

	if expected.is_empty():
		printerr("Missing --expected-token")
		quit(2)
		return

	if Target.AUTOMATION_TOKEN != expected:
		printerr("Token mismatch: expected %s, got %s" % [expected, Target.AUTOMATION_TOKEN])
		quit(1)
		return

	print("GAME_FOUNDRY_STATIC_OK")
	print("GAME_FOUNDRY_TOKEN=%s" % Target.AUTOMATION_TOKEN)
	quit(0)

