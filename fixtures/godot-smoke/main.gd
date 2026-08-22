extends Control

const Target = preload("res://automation_target.gd")
const WIDTH := 640
const HEIGHT := 360

var screenshot_path := ""
var runtime_test := false
var export_self_test := false

func _ready() -> void:
	_parse_arguments()
	_build_fixture()
	print("GAME_FOUNDRY_TOKEN=%s" % Target.AUTOMATION_TOKEN)

	if runtime_test:
		print("GAME_FOUNDRY_RUNTIME_OK")
		get_tree().quit(0)
		return

	if export_self_test:
		print("GAME_FOUNDRY_EXPORT_RUNTIME_OK")
		get_tree().quit(0)
		return

	if not screenshot_path.is_empty():
		_capture_screenshot.call_deferred()

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--runtime-test":
			runtime_test = true
		elif argument == "--export-self-test":
			export_self_test = true
		elif argument.begins_with("--screenshot="):
			screenshot_path = argument.trim_prefix("--screenshot=")

func _build_fixture() -> void:
	var background := ColorRect.new()
	background.color = Color("071126")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var border := Panel.new()
	border.position = Vector2(48, 30)
	border.size = Vector2(544, 300)
	var border_style := StyleBoxFlat.new()
	border_style.bg_color = Color("0d1b33")
	border_style.border_color = Color("4dd7fa")
	border_style.set_border_width_all(3)
	border_style.corner_radius_top_left = 12
	border_style.corner_radius_top_right = 12
	border_style.corner_radius_bottom_left = 12
	border_style.corner_radius_bottom_right = 12
	border.add_theme_stylebox_override("panel", border_style)
	add_child(border)

	var stack := VBoxContainer.new()
	stack.position = Vector2(80, 58)
	stack.size = Vector2(480, 245)
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 13)
	add_child(stack)

	_add_label(stack, "GAME FOUNDRY", 34, Color("f4f8ff"))
	_add_label(stack, "GF-001 AUTOMATION TEST", 20, Color("4dd7fa"))
	_add_label(stack, "Mutation: %s" % Target.AUTOMATION_TOKEN, 20, Color("f5c451"))

	var marker := ColorRect.new()
	marker.custom_minimum_size = Vector2(34, 34)
	marker.color = Color("56e39f")
	stack.add_child(marker)

	_add_label(stack, "PIPELINE FIXTURE", 17, Color("a8b9d8"))

func _add_label(parent: Control, text: String, size: int, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)

func _capture_screenshot() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image.get_width() != WIDTH or image.get_height() != HEIGHT:
		printerr("Unexpected viewport dimensions: %sx%s" % [image.get_width(), image.get_height()])
		get_tree().quit(1)
		return
	var error := image.save_png(screenshot_path)
	if error != OK:
		printerr("Could not save screenshot: %s" % error_string(error))
		get_tree().quit(1)
		return
	print("GAME_FOUNDRY_SCREENSHOT_OK=%s" % screenshot_path)
	get_tree().quit(0)

