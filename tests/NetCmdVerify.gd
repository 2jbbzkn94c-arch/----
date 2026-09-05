extends Node
## apply_command 主机权威执行验证：一条 move / attack 指令应正确驱动 Battle 执行。
## 运行：godot --headless --scene res://tests/NetCmdVerify.tscn
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

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	clear_all()
	# 我方单位 hero_06 在 (3,8)，敌方 hero_13 在 (4,8)
	var p := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	var pi := battle.units.find(p)
	var ei := battle.units.find(e)

	# T1: move 指令 -> 移动到 (3,7)
	battle.apply_command({ "type": "move", "u": pi, "to": [3, 7] })
	await sleep_frames(300)
	print("T1 move指令: cell=%s => %s" % [str(p.cell), "PASS" if p.cell == Vector2i(3, 7) else "FAIL"])

	# T2: attack 指令 -> 敌方掉血
	e.hp = 20; e.max_hp = 20; e.refresh_stats()
	var e0 := e.hp
	battle._sync_ranged_adjacent()
	battle.apply_command({ "type": "attack", "u": pi, "t": ei })
	await sleep_frames(300)
	print("T2 attack指令: 敌方%d->%d => %s" % [e0, e.hp, "PASS" if e.hp < e0 else "FAIL"])

	# T3: 越界/非法 u -> 不崩
	battle.apply_command({ "type": "move", "u": 999, "to": [0, 0] })
	await sleep_frames(10)
	print("T3 非法指令容错: 未崩 => %s" % ["PASS" if true else "FAIL"])

	get_tree().quit()
