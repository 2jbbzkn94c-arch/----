extends Node
## 【2026-10-01·一次性探针·只读·用户「他是落在贴身位置了，然后离开了一个」＋「他替补的是影丸，
##   必须要不贴身才能收尾」】验 `_sub_best_strike_here()`：**远程替补落在贴身位置时，会"退开一格再打"**
##   （贴身 ⇒ 伤害被压成 1、收不掉；退到不贴人的开火格 ⇒ 满额伤害、一刀收）。
##
## 盘面：AI = 白游侠(hero_10，远程 射程2 攻2)@(1,2)｜玩家 = 塔盾@(2,2)（**2 血**，与替补贴身）。
##   ⇒ 贴身打只有 1 伤（收不掉）；走到 (0,2)（不贴人、格距 2）打 ⇒ 2 伤 ⇒ **一刀收**。
##   看点：`_sub_best_strike_here()` 返回的那一手应当是「**走 (0,2) 再打**」，而不是"原地打"或"只走位"。
##
## 输出：PIN|CFG / PIN|原地 / PIN|退回 / PIN|判定 / PIN|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
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
	for i in 2:
		await get_tree().process_frame
	_spawn("hero_10", DataRegistry.Faction.ENEMY, Vector2i(1, 2))
	_spawn("hero_11", DataRegistry.Faction.PLAYER, Vector2i(2, 2))
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_11":
			u.hp = 2
	battle.player_dead = 2
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var sub: Unit = null
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_10":
			sub = u
	if sub == null:
		print("PIN|拿不到替补单位")
		get_tree().quit(0)
		return
	var pool: Array = [sub]
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction != DataRegistry.Faction.ENEMY:
			pool.append(u)
	print("PIN|CFG|噩梦｜替补 %s（射程 %d 攻 %d）@%s｜目标 %s 血 %d（贴身）" % [
		String(sub.hero_id), int(sub.attack_range), int(sub.effective_atk()),
		DataRegistry.cell_txt(sub.cell), _nm(pool), _hp("hero_11")])
	# 贴身那一刀多重
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle, pool)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var su = sim.units[0]
	var st = sim.units[1]
	print("PIN|原地|贴身(格距 1) 那一刀 = %.1f 伤（目标血 %d）⇒ %s" % [
		float(ai._adj_foe_hit_on(sim, st, su)), int(st.hp),
		("收得掉" if float(ai._adj_foe_hit_on(sim, st, su)) >= float(int(st.hp)) else "**收不掉** ⇒ 必须退开")])
	# 几何选的那一手
	var pick: Dictionary = battle._sub_best_strike_here(sub, pool)
	if pick.is_empty():
		print("PIN|退回|`_sub_best_strike_here()` 返回空 ⇒ 会退回短搜索（这条盘面不该发生）")
		print("PIN|判定|FAIL")
		print("PIN|END")
		get_tree().quit(0)
		return
	var mv: Variant = pick.get("move", null)
	var mv_txt := ("原地" if mv == null else DataRegistry.cell_txt(mv))
	var ti := int(pick.get("atk", -1))
	var tname := ("?" if ti < 0 or ti >= pool.size() else String(pool[ti].display_name))
	print("PIN|退回|几何选的一手 = %s 打 %s（目标在 %s）" % [mv_txt, tname,
		DataRegistry.cell_txt(battle._finish_withdraw_target.cell) if battle._finish_withdraw_target != null else "—"])
	var moved_away: bool = (mv != null and Vector2i(mv) != sub.cell)
	print("PIN|判定|%s（退开一格=%s ⇒ %s）" % [
		("PASS" if moved_away else "FAIL"), str(moved_away),
		("正确：贴身收不掉 ⇒ 退到不贴人的开火格，满额一刀收" if moved_away else "**错**：它没退开")])
	print("PIN|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false

func _hp(hid: String) -> int:
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == hid:
			return int(u.hp) if u.alive else 0
	return -1

func _nm(pool: Array) -> String:
	var out: Array = []
	for u in pool:
		if u != null and is_instance_valid(u):
			out.append(String(u.display_name))
	return "、".join(out)
