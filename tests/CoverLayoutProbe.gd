extends Node
## 布局探针：打印主菜单里标题/副标题/按钮/宣传行的精确屏幕矩形，
## 用于设计封面背景的"主体放在哪、哪里必须留空"。
## 运行：godot --headless --scene res://tests/CoverLayoutProbe.tscn
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var m := (load("res://scenes/Menu.tscn") as PackedScene).instantiate()
	add_child(m)
	await get_tree().process_frame
	await get_tree().process_frame
	print(">> 视口 %s" % str(get_viewport().get_visible_rect().size))
	_dump(m, 0)
	get_tree().quit()

func _dump(n: Node, d: int) -> void:
	var pad := "  ".repeat(d)
	if n is Label and not (n as Label).text.is_empty():
		print("%s[Label ] '%s'  rect=%s" % [pad, (n as Label).text.substr(0, 16), str((n as Label).get_global_rect())])
	elif n is Button:
		print("%s[Button] '%s'  rect=%s" % [pad, (n as Button).text, str((n as Button).get_global_rect())])
	for c in n.get_children():
		_dump(c, d + 1)
