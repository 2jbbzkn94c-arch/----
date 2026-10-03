extends Node
## 【2026-10-02·一次性探针·只读·用户「怎么计算挨远程打的时候，又计算成被贴边的了？」】
##   病灶：`_threat_hit_value()` 判定"这一下不贴身（退得掉 ⇒ 按满额算）"之后，**基础攻击力却仍取 `t.eatk`**
##   —— 那是**带"远程被贴身"缓存标记**的值：快照那一刻正贴着人的远程，`eatk` 早被压成 1
##   ⇒ "退开打满"这条分支拿到的还是 1（用户那局：火枪手 攻 4 被记成 1）。
##
## 盘面（内部坐标）：AI 小阴影(1,4) 血9 中毒 · 黄金矿工(0,3) 血20 · **复仇者(2,4)**（负责把火枪手贴住）
##   玩家 毒蛇淑女(0,4) 血8 · 装甲堡垒(2,3) 血28 [坚固] · **火枪手(3,3)** 血20 [圣盾]（攻4 / 射程2 / 移动2）
##   ⇒ 快照时火枪手是"被贴身"的（`ranged_adjacent = true`，eatk = 1），但它**退得掉**、
##     退开之后也打得到小阴影 ⇒ 这一笔应当按 **4** 算。
##
## 用**生产 BattleAI（`src/BattleAI.gd`，difficulty ≤ 2 走的就是它）**跑 ⇒ 改 `src` 立刻能看到差别。
## 输出：RB|… / RB|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2          # ⚠️ 走**生产** BattleAI（src/BattleAI.gd），不走 fork ⇒ 改 src 立刻生效
	await _rebuild()
	GameState.ai_difficulty = 2
	_spawn("hero_15", DataRegistry.Faction.ENEMY, Vector2i(0, 5), 18)
	_spawn("hero_23", DataRegistry.Faction.ENEMY, Vector2i(1, 4), 15)      # ← 本次要评估的目标（d=2）
	_spawn("hero_42", DataRegistry.Faction.ENEMY, Vector2i(2, 4), 20)      # ← **负责把火枪手贴住**（快照时它就贴着）
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(0, 4), 8)
	_spawn("hero_48", DataRegistry.Faction.PLAYER, Vector2i(2, 3), 28)
	var gunner = _spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 3), 20)
	var tank = _all_of("hero_48")
	for t in tank:
		t.add_status(StatusDB.SOLID)
	if gunner != null:
		gunner.add_status(StatusDB.SHIELD)
	var poison: Array = _all_of("hero_23")
	for p in poison:
		p.add_status(StatusDB.POISON)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()      # 真实刷新点：切边 / 出生 / 移动落位…（此刻火枪手被复仇者贴住）
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var d_gun := {}
	for d in (snap["descs"] as Array):
		if String(d.get("hero", "")) == "hero_09":
			d_gun = d
	print("RB|快照|火枪手 ranged_adjacent=%s eatk=%s atk=%s（真实侧 effective_atk=%d）" % [
		str(d_gun.get("ranged_adjacent", "(无此键)")), str(d_gun.get("eatk", "?")), str(d_gun.get("atk", "?")),
		int(gunner.effective_atk())])
	var ai = battle._make_battle_ai()
	if ai == null:
		print("RB|拿不到 AI")
		print("RB|END")
		get_tree().quit(0)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
			snap.get("buff_owner", {}), snap.get("deads", {}))
	var g2 = null
	var tgt = null
	for u in sim.units:
		if u.hero_id == "hero_09":
			g2 = u
		elif u.hero_id == "hero_23":
			tgt = u
	var adj: Array = []
	for u in sim.units:
		if u.alive and u.fn == DataRegistry.Faction.ENEMY:
			adj.append("%s@%s(距%d)" % [String(u.name), str(u.cell), battle.grid.distance(g2.cell, u.cell)])
	print("RB|火枪手@%s 与各 AI 单位的格距：%s" % [str(g2.cell), "、".join(adj)])
	print("RB|模拟盘|火枪手@%s pin_flag=%s eatk=%d pin_buffs=%d｜_sim_free_atk=%d（= 退开后的攻击力）" % [
		str(g2.cell), str(g2.pin_flag), int(g2.eatk), int(g2.pin_buffs), int(ai._sim_free_atk(g2))])
	print("RB|贴身判定|实时相邻=%s（缓存 pin_flag=%s）｜退得掉=%s" % [
		str(ai._sim_enemy_adjacent(sim, g2, g2.cell)), str(g2.pin_flag), str(ai._sim_pin_escapable(sim, g2))])
	var d: int = battle.grid.distance(g2.cell, tgt.cell)
	print("RB|对复仇者@%s|d=%d｜退开能打=%s｜_threat_hit_value=%.1f（**应当是 4 = 退开后的攻击力**）" % [
		str(tgt.cell), d, str(ai._sim_pin_escape_fire_cell(sim, g2, tgt.cell, tgt)),
		ai._threat_hit_value(sim, g2, d, false, tgt.cell, tgt)])
	var info := {}
	var inc: float = ai._incoming_total_on(sim, tgt, tgt.cell, info)
	var parts: Array[String] = []
	for row in (info.get("parts", []) as Array):
		var r: Array = row
		parts.append("%s=%.1f" % [String(r[0]), float(r[1])])
	print("RB|小阴影挨打合计=%.1f（%s）" % [inc, "、".join(parts)])
	var ok: bool = ai._threat_hit_value(sim, g2, d, false, tgt.cell, tgt) >= 4.0
	print("RB|判定|%s（改前应为 1.0 ⇒ FAIL；改后 4.0 ⇒ PASS）" % ("**PASS**" if ok else "**FAIL**"))
	print("RB|END")
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
