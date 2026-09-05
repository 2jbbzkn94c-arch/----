extends Node
## 静态加载探针：仅验证脚本能编译、Main/NetLobby 场景能实例化并进入 arena 分支。
## 结果写入 %TEMP%/dsh_probe_result.txt（避免 headless stdout 丢失）。
## 运行：godot --headless --path <proj> --scene res://tests/StaticLoadProbe.tscn

var _result_path := ""

func _ready() -> void:
	_result_path = "D:/Game creating/战旗/tests/probe_result.txt"
	_write("probe start\n")
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
	# 1) 实例化 Main 场景（非联机普通）
	GameState.reset_online()
	GameState.arena_mode = false
	var b1 = load("res://scenes/Main.tscn").instantiate()
	add_child(b1)
	await get_tree().process_frame
	_write("main_normal state=%d units=%d\n" % [b1.state, b1.units.size()])
	b1.queue_free()
	await get_tree().process_frame

	# 2) 实例化 Main 场景（非联机竞技场 -> ARENA_DRAFT）
	GameState.reset_online()
	GameState.arena_mode = true
	var b2 = load("res://scenes/Main.tscn").instantiate()
	add_child(b2)
	await get_tree().process_frame
	_write("main_arena state=%d pending=%s\n" % [b2.state, str(b2._arena_pending)])
	await get_tree().process_frame
	b2.queue_free()
	await get_tree().process_frame

	# 3) 实例化 NetLobby
	var lb = load("res://scenes/NetLobby.tscn").instantiate()
	add_child(lb)
	await get_tree().process_frame
	_write("netlobby ok\n")
	lb.queue_free()

	_write("probe done\n")
	get_tree().quit()
