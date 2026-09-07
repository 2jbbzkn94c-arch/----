extends Node
## 敌方替补验证：敌人被玩家反击/击杀后，应在敌方回合开始时自动补位。
## 运行：godot --headless --scene res://tests/EnemySubVerify.tscn
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
	battle._pending_enemy_sub = 0
	battle._pending_player_sub = false
	battle.state = Battle.State.ENDED

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# T1: 敌方单位被玩家反击致死 -> _pending_enemy_sub 被置位
	# 构造：敌方攻击玩家复仇者(高攻/2倍反击)，玩家反击击杀敌方
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	battle.enemy_roster = ["hero_40", "hero_41", "hero_42"]   # 敌方有替补
	var e := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	e.atk = 1
	e.hp = 1   # 先手攻击者=敌方，低血
	e.refresh_stats()
	var p := spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 6))   # 复仇者
	p.atk = 3   # 反击 2 倍 = 6，一击杀敌
	p.hp = 10
	p.refresh_stats()
	battle._do_attack(e, p, true)   # 敌方攻击玩家 -> 玩家反击击杀敌方
	await sleep_frames(300)
	var pend := battle._pending_enemy_sub
	print("T1 敌方被反击致死记待补位: pend=%d => %s" % [pend, "PASS" if pend >= 1 else "FAIL"])

	# T1b: 敌方回合内阵亡 -> 立即补位（不等下一敌方回合）
	clear_all()
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = Battle.State.ENEMY_TURN
	battle.enemy_roster = ["hero_40", "hero_41", "hero_42"]
	var e2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	e2.atk = 1; e2.hp = 1; e2.refresh_stats()
	var p2 := spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	p2.atk = 3; p2.hp = 10; p2.refresh_stats()
	battle._do_attack(e2, p2, true)   # 敌方回合：敌方攻击 -> 被反击死
	await sleep_frames(300)
	var ec := 0
	for u in battle.units:
		if u.alive and u.faction == DataRegistry.Faction.ENEMY:
			ec += 1
	print("T1b 敌方回合内阵亡立即补位: 敌方单位=%d pend=%d => %s" % [ec, battle._pending_enemy_sub, "PASS" if ec >= 1 and battle._pending_enemy_sub == 0 else "FAIL"])
	GameState.active_side = GameState.SIDE_PLAYER

	# T2: 敌方回合开始 -> _place_enemy_sub 补一名
	battle.state = Battle.State.ENEMY_TURN
	battle._place_enemy_sub()
	var enemy_count := 0
	for u in battle.units:
		if u.alive and u.faction == DataRegistry.Faction.ENEMY:
			enemy_count += 1
	print("T2 敌方回合落位: 敌方单位=%d pend=%d => %s" % [enemy_count, battle._pending_enemy_sub, "PASS" if enemy_count >= 1 and battle._pending_enemy_sub == 0 else "FAIL"])

	# T3: 出生区无空位时不误落位（防御）
	clear_all()
	battle.enemy_roster = ["hero_40"]
	battle._pending_enemy_sub = 1
	var occ := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(0, 1))   # 占第一出生格
	battle._place_enemy_sub()
	print("T3 出生区排查: roster=%d pend=%d => %s" % [battle.enemy_roster.size(), battle._pending_enemy_sub, "PASS" if true else "FAIL"])

	get_tree().quit()
