extends Node2D

const WEB_EXPORT_MARKER := "GAME_FOUNDRY_WEB_EXPORT_FIXTURE_OK"


func _ready() -> void:
	print(WEB_EXPORT_MARKER)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 360), Color("07132a"))
	draw_circle(Vector2(320, 165), 72, Color("4cc9f0"))
	draw_circle(Vector2(295, 150), 9, Color("07132a"))
	draw_circle(Vector2(345, 150), 9, Color("07132a"))
	draw_arc(Vector2(320, 175), 28, 0.2, PI - 0.2, 32, Color("07132a"), 6)
