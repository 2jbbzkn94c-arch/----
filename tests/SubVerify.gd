extends Node
## 替补触发验证：玩家英雄在自己回合被反击击杀后，应立即进入替补选择（不等下一回合）。
## 运行：godot --headless --scene res://tests/SubVerify.tscn
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
	battle._preview_cells.clear()
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
	clear_all()
	# 玩家英雄(无被动) 1血 紧邻敌方高攻英雄；玩家攻击 -> 敌方反击致死
	battle.player_roster = ["hero_42", "hero_43"]   # 有替补可用
	battle.state = Battle.State.PLAYER_INPUT
	var p := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	p.hp = 1
	var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	e.atk = 5
	e.refresh_stats()
	battle._do_attack(p, e, false)
	# 攻击(0.12s)+反击(0.1s+0.12s)动画较长，多等
	await sleep_frames(200)
	var st := int(battle.state)
	var sub_now := st == Battle.State.SUBSTITUTING or st == Battle.State.PLACE_SUB
	print("T1 反击致死后立即替补: state=%d pending=%s => %s" % [st, str(battle._pending_player_sub), "PASS" if sub_now and not battle._pending_player_sub else "FAIL"])

	# 对照：无替补时不应卡在替补态（应能继续）
	clear_all()
	battle.player_roster = []
	battle.state = Battle.State.PLAYER_INPUT
	var p2 := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	p2.hp = 1
	var e2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	e2.atk = 5
	e2.refresh_stats()
	battle._do_attack(p2, e2, false)
	await sleep_frames(200)
	var st2 := int(battle.state)
	print("T2 无替补不卡替补: state=%d => %s" % [st2, "PASS" if st2 != Battle.State.SUBSTITUTING else "FAIL"])

	get_tree().quit()
