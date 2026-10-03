extends Node
## 【2026-10-02·一次性探针·只读】用户实机（AI 替补日志）：
##   `[替补] 影丸 按几何选的一手（不走短搜索）：原地打 嬉皮死神（约 5 伤）`
##   而实战里那一刀只打出 **1 伤**（影丸是 `<远程>`，落在**贴身**位置 ⇒ 基础攻击压成 1）⇒ 承诺的"斩杀"没发生。
##
## 盘面（内部 0 基）：**影丸 hero_07**（远程/疾行，攻 5）落在 (3,2)，**嬉皮死神 hero_30** 就贴在他旁边 (3,3)，
##   另有一格"退开再打"的开火位（与嬉皮死神格距 2、影丸走得到）。
##
## 三样并排打：
##   ① 同一格里两把尺子的读数：`_adj_foe_hit_on()`（**旧尺**：`_threat_hit_value(d=1)`，把"退得开"当满额）
##      vs `_sim_hit_est()`（**真尺**：站在这一格打出去多少 —— 远程被贴身就是 1+buff）；
##   ② `Battle._sub_best_strike_here()` **实际选的那一手**（`move` 是不是 null = 原地）；
##   ③ 判读行：那一手按真尺能打多少（= 实战会打出多少）。
## 输出：SG|… / SG|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2          # 生产 BattleAI（这条链在 Battle.gd 里，难度无关）
	await _rebuild()
	GameState.ai_difficulty = 2
	var A := Vector2i(3, 2)              # 影丸落点（贴身处）
	var B := Vector2i(3, 3)              # 嬉皮死神（就贴着他）
	var ying = _spawn("hero_07", DataRegistry.Faction.ENEMY, A, 14)     # 影丸（远程/疾行）
	var death = _spawn("hero_30", DataRegistry.Faction.PLAYER, B, 20)   # 嬉皮死神
	if ying == null or death == null:
		print("SG|盘面没搭起来")
		print("SG|END")
		get_tree().quit(0)
	# 找一个"退开再打"的开火位：与嬉皮死神格距 2、影丸走得到、空格、界内
	var far := Vector2i(-99, -99)
	for c in battle.grid.all_cells():
		if c == A or c == B or battle.occupancy.has(c):
			continue
		if battle.grid.distance(c, B) != 2:
			continue
		if battle.grid.distance(A, c) > 3:
			continue
		if battle.grid.in_bounds(c):
			far = c
			break
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	print("SG|盘面|影丸@%s（界面 %s，攻%d 移%d 射%d）｜嬉皮死神@%s（界面 %s，格距 %d）｜退开位 %s（界面 %s，与目标格距 %d）" % [
		str(A), DataRegistry.cell_txt(A), int(ying.effective_atk()), int(ying.effective_move()),
		int(ying.attack_range), str(B), DataRegistry.cell_txt(B), battle.grid.distance(A, B),
		str(far), DataRegistry.cell_txt(far), battle.grid.distance(far, B)])
	var pool: Array = [ying, death]      # 与 `_plan_enemy_late_sub()` 同一形状：池首 = 替补自己
	var snap := BattleSnapshot.collect(battle, pool)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("SG|拿不到 AI")
		print("SG|END")
		get_tree().quit(0)
	ai.difficulty = GameState.ai_difficulty
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var su = sim.units[0]
	var tgt = null
	for u in sim.units:
		if u.hero_id == "hero_30":
			tgt = u
	print("SG|两把尺子|（同一格：旧尺 `_adj_foe_hit_on` / 真尺 `_sim_hit_est`）")
	for c_v in [A, far]:
		var c: Vector2i = c_v
		if c.x == -99:
			continue
		su.cell = c
		if not sim.occ.has(c):
			sim.occ[c] = su
		ai._sim_refresh_pins(sim)          # 与 `_sub_best_strike_here()` 里同款：按真实刷新点重算贴身
		var can: bool = ai._threat_fire_ok_at(sim, su, c, tgt.cell, tgt)
		print("SG|　%s（界面 %s，与目标格距 %d）｜打得到=%s｜旧尺=%.1f｜**真尺=%.1f**｜贴身=%s" % [
			str(c), DataRegistry.cell_txt(c), battle.grid.distance(c, tgt.cell), str(can),
			float(ai._adj_foe_hit_on(sim, tgt, su)), float(ai._sim_hit_est(sim, su, tgt)),
			str(ai._sim_enemy_adjacent(sim, su, c))])
		sim.occ.erase(c)
	var built: Dictionary = battle._sub_best_strike_here(ying, pool)
	print("SG|实际选的那一手|%s" % str(built))
	if not built.is_empty():
		var mv = built.get("move")
		var ti := int(built.get("atk", -1))
		var nm := ("?" if ti < 0 else String(sim.units[ti].name))
		# 真尺复核：把影丸摆到那一手的开火格，看这一刀到底多重
		var fire: Vector2i = (A if mv == null else Vector2i(mv))
		su.cell = fire
		if not sim.occ.has(fire):
			sim.occ[fire] = su
		ai._sim_refresh_pins(sim)
		var real := float(ai._sim_hit_est(sim, su, sim.units[ti] if ti >= 0 else tgt))
		print("SG|★判读★|那一手 = %s打 %s｜开火格 %s（界面 %s）｜**实战会打出 %.1f 伤**（目标 %.0f 血）⇒ %s" % [
			("原地" if mv == null else ("走到 %s 再" % DataRegistry.cell_txt(Vector2i(mv)))), nm,
			str(fire), DataRegistry.cell_txt(fire), real,
			float(sim.units[ti].hp) if ti >= 0 else 0.0,
			("**收得掉**" if ti >= 0 and real >= float(sim.units[ti].hp) else "**收不掉**（日志那句「约 N 伤」是虚的）")])
	print("SG|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i, hp: int = 0):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		if hp > 0:
			u.hp = hp
	return u

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
