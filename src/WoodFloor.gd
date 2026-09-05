class_name WoodFloor
extends Control
## 酒馆木地板背景（纯色版）：单一暖木色，无任何线条/暗角/纹理。
## 作为各界面/棋盘的最底层背景，避免与棋盘格线或内容边缘混淆。

func _ready() -> void:
	resized.connect(queue_redraw)
	queue_redraw()

func _draw() -> void:
	var s := size
	if s.x <= 0.0 or s.y <= 0.0:
		var vs := get_viewport().get_visible_rect().size
		s = vs
	# 底色：雾蓝灰（低饱和冷灰，柔和护眼；替代原木色）
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.54, 0.60, 0.65))
