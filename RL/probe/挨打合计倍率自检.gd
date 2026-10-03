extends Node
## 【2026-10-02·一次性探针·只读·用户「为什么烛火被暗域位移后，死神可以打 6 伤，但只记了 3 伤」】
##   用户那局的盘面（转储）＋ 那条 AI 计划走完之后的落点，逐格问三件事：
##     ① 目标这一格**孤立吗**（`_is_isolated` 真实侧 / `_sim_isolated_at` 模拟侧，两把尺子一起打）
##     ② 嬉皮死神（hero_30，打孤立 ×2）在这一格是 ×1 还是 ×2（`_sim_mult_at`）
##     ③ 这一格的"下回合挨打合计"是多少、逐笔是谁打的（`_incoming_total_on`，就是日志那一行）
##   两格：原地 (2,3)界面 / 位移落点 (3,3)界面（= 内部 (1,2) 与 (2,2)）。
##   输出：INC|… / INC|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _rebuild()
	# ---- 盘面 = 用户转储（界面坐标 → 内部 = −1）＋ 那条计划走完之后的落点 ----
	# AI（ENEMY）：荆棘树人 (2,2)→内(1,1) · 烛火 (2,3)→内(1,2) · 白游侠 (3,2)→内(2,1)
	_spawn("hero_49", DataRegistry.Faction.ENEMY, Vector2i(1, 1))
	_spawn("hero_17", DataRegistry.Faction.ENEMY, Vector2i(1, 2))
	_spawn("hero_10", DataRegistry.Faction.ENEMY, Vector2i(2, 1))
	# 玩家：嬉皮死神 (3,5)→内(2,4)（带盾）· 暗域 (4,6)→内(3,5) · 战锤 (2,6)→内(1,5)
	var reaper = _spawn("hero_30", DataRegistry.Faction.PLAYER, Vector2i(2, 4))
	if reaper != null:
		reaper.add_status(StatusDB.SHIELD)
	_spawn("hero_27", DataRegistry.Faction.PLAYER, Vector2i(3, 5))
	_spawn("hero_25", DataRegistry.Faction.PLAYER, Vector2i(1, 5))
	battle.obstacles[Vector2i(1, 3)] = 2
	battle.obstacles[Vector2i(3, 3)] = 2
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	# ---- 建模拟盘 ----
	var ai = battle._make_battle_ai()
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
			snap.get("buff_owner", {}), snap.get("deads", {}))
	var t17 = null
	var a30 = null
	for su in sim.units:
		if su.hero_id == "hero_17":
			t17 = su
		elif su.hero_id == "hero_30":
			a30 = su
	if t17 == null or a30 == null:
		print("INC|模拟盘里找不到 烛火/嬉皮死神 ⇒ 探针作废")
		print("INC|END")
		get_tree().quit(0)
	var orig := Vector2i(1, 2)      # 烛火这回合走到的格（界面 (2,3)）
	var land := Vector2i(2, 2)      # 暗域换位落点（界面 (3,3)）
	print("INC|盘面|AI 树人%s 烛火%s 白游侠%s ｜玩家 死神%s 暗域%s 战锤%s（内部坐标）" % [
		str(Vector2i(1, 1)), str(orig), str(Vector2i(2, 1)), str(Vector2i(2, 4)),
		str(Vector2i(3, 5)), str(Vector2i(1, 5))])
	# 两把尺子的一致性：同一格，真实侧 `_is_isolated` vs 模拟侧 `_sim_isolated_at`
	var real17 = null
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_17":
			real17 = u
	var real30 = null
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_30":
			real30 = u
	for c in [orig, land]:
		var near: Array = []
		for su2 in sim.units:
			if su2.alive and su2.fn == DataRegistry.Faction.ENEMY and su2 != t17 and su2.hero_id != "hero_17":
				near.append("%s@%s(距%d)" % [su2.hero_id, str(su2.cell), battle.grid.distance(c, su2.cell)])
		var iso_sim: bool = ai._sim_isolated_at(sim, t17, c, a30)
		var iso_real: bool = false
		var keep: Vector2i = real17.cell
		real17.cell = c
		iso_real = battle._is_isolated(real17, real30)
		real17.cell = keep
		var mult: int = ai._sim_mult_at(sim, a30, t17, c)
		var dist: int = ai.walk_dist(sim, a30.cell, c)
		var thr: float = ai._threat_hit_value(sim, a30, dist, false, c, t17)
		var bonus: int = ai._sim_turn_start_atk_bonus(sim, a30)
		var after: float = ai._hit_after_target_mods(sim, t17, c, (thr + float(bonus)) * float(mult))
		# ① 日志**主句**那条路：允许展开位移（`no_displace = false`，默认）
		var oA := {}
		var vA: float = ai._incoming_total_on(sim, t17, c, oA)
		# ② 日志**尾部"被位移后"**那条路：`no_displace = true`（只算这一格自己的账）
		var oB := {}
		var vB: float = ai._incoming_total_on(sim, t17, c, oB, false, true)
		var fmt := func(o: Dictionary, v: float) -> String:
			var bits: Array = []
			for p in (o.get("parts", []) as Array):
				if p is Array and (p as Array).size() >= 2:
					bits.append("%s %.0f" % [String(p[0]), float(p[1])])
			return "%.0f（%s）%s" % [v, ("＋".join(bits) if bits.size() > 0 else "没人够得到"),
				("［位移胜出→%s，原地 %.0f］" % [str(o.get("disp_cell", "")), float(o.get("base_total", 0.0))]) if bool(o.get("displaced", false)) else ""]
		var lands: Array = ai._displace_landing_cells(sim, t17, c)
		print("INC|格%s|同阵营队友：%s｜孤立(模拟)=%s 孤立(真实)=%s｜嬉皮死神倍率=×%d" % [
			str(c), ("无" if near.is_empty() else "、".join(near)), str(iso_sim), str(iso_real), mult])
		print("INC|　主句(可位移)=%s" % fmt.call(oA, vA))
		print("INC|　该格自身(no_displace)=%s" % fmt.call(oB, vB))
		print("INC|　位移候选落点=%s" % str(lands))
		print("INC|拆账|嬉皮死神 eatk=%d atk=%d｜walk_dist=%d｜_threat_hit_value=%.1f(+回合开始加成%d)｜倍率=×%d｜单笔算出来=%.1f" % [
			int(a30.eatk), int(a30.atk), dist, thr, bonus, mult, after])
	# 对照：把白游侠拿掉（模拟里设死）⇒ 看 (2,2) 会不会变孤立、倍率会不会变 2
	for su3 in sim.units:
		if su3.hero_id == "hero_10":
			su3.alive = false
			if sim.occ.get(su3.cell, null) == su3:
				sim.occ.erase(su3.cell)
	var iso2: bool = ai._sim_isolated_at(sim, t17, land, a30)
	var mult2: int = ai._sim_mult_at(sim, a30, t17, land)
	print("INC|对照·去掉白游侠|位移落点%s 孤立=%s｜倍率=×%d（说明是谁的相邻在压着倍率）" % [
		str(land), str(iso2), mult2])
	print("INC|END")
	get_tree().quit(0)

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
	GameState.active_side = GameState.SIDE_PLAYER
	battle.state = battle.State.PLAYER_INPUT

func _spawn(hid: String, fn, cell: Vector2i):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
	return u
