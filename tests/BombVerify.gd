extends Node
## 炸弹触发验证：
## 1) 普通英雄"经过"炸弹格（非终点）也会爆炸；
## 2) 炸弹人经过/触碰炸弹安全。
## 运行：godot --headless --scene res://tests/BombVerify.tscn
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
	battle.state = Battle.State.ENDED

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# T1: 普通英雄经过中途炸弹格 -> 爆炸
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var u := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	u.hp = 10; u.move_range = 3; u.refresh_stats()
	# 占用 (4,9)，迫使 (3,8)->(5,8) 只能经 (4,8)（炸弹格）
	var occupy := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 9))
	u.faction = DataRegistry.Faction.PLAYER
	battle.bombs[Vector2i(4, 8)] = true   # 路径必经格
	if battle.board_view:
		battle.board_view.bombs = battle.bombs
	var bp := battle.grid.find_path(Vector2i(3, 8), Vector2i(5, 8), battle._current_path_blockers(u))
	print("  PATH=", bp)
	battle._do_move(u, Vector2i(5, 8), true)
	await sleep_frames(300)
	var onbomb := battle.bombs.has(Vector2i(4, 8))
	print("T1 普通英雄经过炸弹爆炸: hp=%d(原10) 炸后消失=%s 终格=%s => %s" % [u.hp, str(not onbomb), str(u.cell), "PASS" if u.hp < 10 and not onbomb else "FAIL"])

	# T2: 炸弹人经过炸弹安全
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var b := spawn("hero_35", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	b.hp = 10; b.move_range = 3; b.refresh_stats()
	battle.bombs[Vector2i(4, 8)] = true
	if battle.board_view:
		battle.board_view.bombs = battle.bombs
	battle._do_move(b, Vector2i(5, 8), true)
	await sleep_frames(300)
	print("T2 炸弹人经过安全: hp=%d(原10) 炸保留=%s => %s" % [b.hp, str(battle.bombs.has(Vector2i(4, 8))), "PASS" if b.hp == 10 else "FAIL"])

	get_tree().quit()
