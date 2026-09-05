extends Node
## 障碍重开探针：连续两次调用 _place_obstacles（中间清空），比较位置是否变化。
var battle: Battle
var _result_path := "D:/Game creating/战旗/tests/probe_result.txt"

func _ready() -> void:
	_write("start\n")
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _write(s: String) -> void:
	var f := FileAccess.open(_result_path, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_string(s)
		f.close()
	else:
		f = FileAccess.open(_result_path, FileAccess.WRITE)
		if f:
			f.store_string(s)
			f.close()

func _run() -> void:
	await get_tree().process_frame
	# 第一次
	battle.obstacles.clear()
	battle._place_obstacles()
	var first: Array = battle.obstacles.keys()
	_write("first=%s\n" % [str(first)])
	# 第二次（模拟重开：清空后重新生成）
	battle.obstacles.clear()
	battle._refresh_board()
	battle._place_obstacles()
	var second: Array = battle.obstacles.keys()
	_write("second=%s\n" % [str(second)])
	_write("same=%s\n" % [str(first.hash() == second.hash())])
	_write("done\n")
	get_tree().quit()
