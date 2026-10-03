extends Node
## 【2026-10-02·一次性探针·只读·用户那局：远程（火枪手，攻4/射程2）在"挨打合计"里只记 1】
##   做法：按转储**原样重建**这一回合（界面坐标 −1 = 内部），用**同一个档位（噩梦1 = 难度4，读 噩梦1.json）**
##   跑一次 `ai.search()`，然后把 `last_decision_text`（= 控制台那段"敌方 AI 本回合…"）原样打出来 ⇒
##   与用户贴的日志逐行对齐；再把该局 **end_sim（走完之后的盘面）** 上每个单位的坐标、以及
##   火枪手那一笔的 `贴身/退得掉/退开能打` 打出来，回答"它到底退不退得掉"。
##
## 输出：RNF|… / RNF|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 4          # 噩梦1（用户日志抬头"上限 120s" ⇒ 就是这个档）
	await _rebuild()
	GameState.ai_difficulty = 4          # `_make_battle_ai()` 之前再设一次（与其它探针同款）
	# ---- 转储（界面坐标）→ 内部 = −1 ----
	_spawn("hero_15", DataRegistry.Faction.ENEMY, Vector2i(1, 4), 9)     # 小阴影 (2,5) 血9 [中毒]
	_spawn("hero_42", DataRegistry.Faction.ENEMY, Vector2i(0, 3), 20)    # 黄金矿工 (1,4) 血20
	_spawn("hero_23", DataRegistry.Faction.ENEMY, Vector2i(1, 3), 15)    # 复仇者 (2,4) 血15 [中毒]
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(0, 4), 8)    # 毒蛇淑女 (1,5) 血8
	_spawn("hero_48", DataRegistry.Faction.PLAYER, Vector2i(2, 3), 28)   # 装甲堡垒 (3,4) 血28 [坚固]
	var gunner = _spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 3), 20)   # 火枪手 (4,4) 血20 [圣盾]
	if gunner != null:
		gunner.add_status(StatusDB.SHIELD)
	for si in _all_of("hero_15") + _all_of("hero_23"):
		si.add_status(StatusDB.POISON)
	var tank = _all_of("hero_48")
	for t in tank:
		t.add_status(StatusDB.SOLID)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var ai = battle._make_battle_ai()
	if ai == null:
		print("RNF|拿不到 AI（档位 4 的权重/副本有问题）")
		print("RNF|END")
		get_tree().quit(0)
	ai.difficulty = 4
	ai.log_decisions = true               # 让它把那段决策文本留下（`last_decision_text`）
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
			snap.get("buff_owner", {}), snap.get("deads", {}))
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("RNF|CFG|难度=4｜计划步数=%d｜墙钟=%.1fs｜超时=%s" % [
		plan.size(), float(Time.get_ticks_msec() - t0) / 1000.0, str(ai.last_search_timeout)])
	print("RNF|决策文本|" + str(ai.get("last_decision_text")))
	# ---- end_sim 上各单位在哪、火枪手那一笔按几算 ----
	var end_sim = ai._plan_end_state(sim, plan)
	var pos: Array = []
	for u in end_sim.units:
		if u != null and u.alive:
			pos.append("%s@%s(%s)" % [String(u.name), str(u.cell),
				("我方" if u.fn == DataRegistry.Faction.ENEMY else "玩家")])
	print("RNF|end_sim 盘面|" + "｜".join(pos))
	var gun2 = null
	for u in end_sim.units:
		if u != null and u.alive and u.hero_id == "hero_09":
			gun2 = u
	if gun2 != null:
		print("RNF|火枪手(end)|@%s 贴身=%s 退得掉=%s 移动力=%d" % [
			str(gun2.cell), str(ai._sim_enemy_adjacent(end_sim, gun2, gun2.cell)),
			str(ai._sim_pin_escapable(end_sim, gun2)), ai._threat_emove_next(end_sim, gun2)])
		for tg in end_sim.units:
			if tg != null and tg.alive and tg.fn == DataRegistry.Faction.ENEMY:
				var d: int = battle.grid.distance(gun2.cell, tg.cell)
				print("RNF|　对%s@%s|d=%d 退开能打=%s 这一笔=%.1f（贴身 %d / 满额 %d）" % [
					String(tg.name), str(tg.cell), d,
					str(ai._sim_pin_escape_fire_cell(end_sim, gun2, tg.cell, tg)),
					ai._threat_hit_value(end_sim, gun2, d, false, tg.cell, tg),
					int(ai._sim_pinned_atk(gun2)), int(ai._sim_free_atk(gun2))])
	print("RNF|END")
	get_tree().quit(0)

func _all_of(hid: String) -> Array:
	var out: Array = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.hero_id == hid:
			out.append(u)
	return out

func _rebuild() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN

func _spawn(hid: String, fn, cell: Vector2i, hp: int = 0):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		if hp > 0:
			u.hp = hp
	return u
