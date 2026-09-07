extends Node
## submit_move 联机分支验证：联机主机 -> 本地执行；联机客户端 -> 不本地执行（只发指令）。
## 运行：godot --headless --scene res://tests/NetSubmitVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func clear_all() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.PLAYER_INPUT

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _run() -> void:
	# T1: 联机主机 -> submit_move 本地执行
	clear_all()
	GameState.is_online = true
	GameState.is_host = true
	var p := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var pi := battle.units.find(p)
	battle.submit_move(pi, Vector2i(3, 7))
	await sleep_frames(300)
	print("T1 联机主机submit_move执行: cell=%s => %s" % [str(p.cell), "PASS" if p.cell == Vector2i(3, 7) else "FAIL"])

	# T2: 联机客户端 -> submit_move 不本地执行（只发指令）
	clear_all()
	GameState.is_host = false
	var c := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var ci := battle.units.find(c)
	battle.submit_move(ci, Vector2i(3, 7))
	await sleep_frames(300)
	print("T2 联机客户端submit_move不执行: cell=%s => %s" % [str(c.cell), "PASS" if c.cell == Vector2i(3, 6) else "FAIL"])

	GameState.is_online = false
	GameState.is_host = false
	get_tree().quit()
