extends Node
## 【2026-10-02·一次性探针·只读】用户问的那条：「**被贴身的远程、退不开时，能不能打到 `d≥2` 那一格**」
##   （口径：「退不开且 d>1 ⇒ 应该记 0」）—— 本探针把"**门**"（`_threat_can_hit`）与"**值**"
##   （`_threat_hit_value`）与"**账**"（`_incoming_total_on` 的逐笔）三样并排打出来：
##   · **A 盘（够不到）**：火枪手被贴住、退不开、目标在 `d≥4`（它的"移动力 + 1"都够不着）
##     ⇒ 这一枪**不存在**（它只能走到目标旁边再打"贴身那一枪"，而贴身位一个都走不到）。
##   · **B 盘（够得到）**：同一个人、目标在 `d=3` ⇒ 真实伤害 = **1 伤**（走过去贴住、射程压 1 打一枪）。
##   ⇒ 判读：若 A 盘的账是 **0**、B 盘是 **1**，说明"门"已经把误记挡住了（那条只是 `_threat_hit_value()`
##     裸调时的数、生产账里到不了）；若 A 盘记了 **1**，就是用户说的那个 bug。
##
## 用**生产 BattleAI**（difficulty ≤ 2 走的就是 `src/BattleAI.gd`）⇒ 改 `src` 立刻见效。
## 输出：PK|… / PK|END

const GUNNER := "hero_09"     # 火枪手（远程：攻 4 / 移 2 / 射 2）
const PINNER := "hero_16"     # 波盾（**没有 <嘲讽>** ⇒ 不会把这一枪吸走；它只负责"贴住"火枪手）
const FAR := "hero_15"        # 小阴影（A 盘的目标：远到够不着）
const NEAR := "hero_40"       # 红帽（B/C/D 盘的目标：够得到）
const FILLERS := ["hero_45", "hero_42", "hero_10"]   # 环上另外三个占位（都没有 <嘲讽>）

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2
	await _rebuild()
	GameState.ai_difficulty = 2
	var A := Vector2i(-99, -99)
	for c in battle.grid.all_cells():          # 起点 = 第一个界内格（靠角 ⇒ 对角那一头足够远）
		if not battle.occupancy.has(c):
			A = c
			break
	var pin_cell := Vector2i(-99, -99)
	for n in battle.grid.neighbors(A):
		if battle.grid.in_bounds(n) and not battle.occupancy.has(n):
			pin_cell = n
			break
	var far_cell := Vector2i(-99, -99)
	var far_d := -1
	var near_cell := Vector2i(-99, -99)
	for c in battle.grid.all_cells():
		if c == A or c == pin_cell or battle.occupancy.has(c):
			continue
		var dd: int = battle.grid.distance(A, c)
		if dd > far_d:
			far_d = dd
			far_cell = c                       # A 盘 = **最远的那一格**（远到"移动力 + 射程"都够不着）
	for c in battle.grid.all_cells():
		if c == A or c == pin_cell or c == far_cell or battle.occupancy.has(c):
			continue
		if battle.grid.distance(A, c) == 3:
			near_cell = c                      # B 盘 = d=3（走两步过去贴住再打）
			break
	_spawn(GUNNER, DataRegistry.Faction.PLAYER, A, 20)
	_spawn(PINNER, DataRegistry.Faction.ENEMY, pin_cell, 15)
	if far_cell.x != -99:
		_spawn(FAR, DataRegistry.Faction.ENEMY, far_cell, 16)
	if near_cell.x != -99:
		_spawn(NEAR, DataRegistry.Faction.ENEMY, near_cell, 16)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()      # 真实刷新点：切边 / 出生 / 移动落位…（此刻火枪手被复仇者贴住）
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("PK|拿不到 AI")
		print("PK|END")
		get_tree().quit(0)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var g2 = null
	for u in sim.units:
		if u.hero_id == GUNNER:
			g2 = u
	print("PK|盘面|火枪手@%s（缓存 eatk=%d｜面板攻击=%d｜移%d 射%d ⇒ 移动力+射程 = %d）｜贴住它的=%s@%s｜实时相邻=%s｜退得掉=%s｜_sim_free_atk=%d" % [
		str(g2.cell), int(g2.eatk), int(g2.atk), int(g2.emove), int(g2.atk_range),
		int(ai._threat_emove_next(sim, g2)) + int(g2.atk_range), PINNER, str(pin_cell),
		str(ai._sim_enemy_adjacent(sim, g2, g2.cell)), str(ai._sim_pin_escapable(sim, g2)),
		int(ai._sim_free_atk(g2))])
	print("PK|格子|火枪手起点 %s ⇒ 贴身位 %s / A盘目标 %s（d=%d）/ B盘目标 %s（d=%d）" % [
		str(A), str(pin_cell), str(far_cell), battle.grid.distance(A, far_cell),
		str(near_cell), battle.grid.distance(A, near_cell)])
	for u in sim.units:
		if u.hero_id != FAR and u.hero_id != NEAR:
			continue
		var d: int = battle.grid.distance(g2.cell, u.cell)
		var hit: bool = ai._threat_can_hit(sim, g2, u.cell, u)
		var raw: float = ai._threat_hit_value(sim, g2, d, false, u.cell, u)
		var info := {}
		var inc: float = ai._incoming_total_on(sim, u, u.cell, info)
		var parts: Array[String] = []
		for row in (info.get("parts", []) as Array):
			var r: Array = row
			parts.append("%s=%.1f" % [String(r[0]), float(r[1])])
		print("PK|%s@%s|d=%d｜门(_threat_can_hit)=%s｜裸值(_threat_hit_value)=%.1f｜**挨打合计=%.1f**（%s）" % [
			String(u.name), str(u.cell), d, ("能打到" if hit else "**够不到**"), raw, inc,
			("、".join(parts) if parts.size() > 0 else "没有来源")])
		# 机制：它这一回合能走到的每一格，逐个看"从那儿能不能打到这一格"（= 门与值共用的那把尺子）
		var wd := {}
		var wcells: Array = ai._sim_walk_cells(sim, g2.cell, ai._threat_emove_next(sim, g2),
			(g2.skills as Array).has(DataRegistry.Skill.INFILTRATE))
		for c in wcells:
			if ai._cell_in_range(sim, g2, c, u.cell):
				wd[c] = "打得到(距%d%s)" % [battle.grid.distance(c, u.cell),
					("，那一格还贴着人" if ai._sim_enemy_adjacent(sim, g2, c) else "，那一格不贴人")]
		print("PK|%s 机制|能走 %d 格；其中开火位 %d 个%s｜退得掉=%s｜退开还能打到这格=%s" % [
			String(u.name), wcells.size(), wd.size(),
			("（" + str(wd.keys()).replace(" ", "") + "）" if wd.size() > 0 else ""),
			str(ai._sim_pin_escapable(sim, g2)), str(ai._sim_pin_escape_fire_cell(sim, g2, u.cell, u))])
	print("PK|END-cd|下面进入 C/D 盘（正对照：**退不开、但真的能打一枪**）")
	await _arm_pinned_shot()
	print("PK|END")
	get_tree().quit(0)

## 搭一个"**退不开 + 又能打一枪**"的盘面：
##   ① 选邻格最多的起点 A（内部格 ⇒ 一圈 6 格）；
##   ② 用 4 个我方单位占掉环上的 4 格 —— 六边形里**相邻的两个环格互为邻格** ⇒ 剩下的空格全被它们贴住
##      ⇒ 火枪手停在环上任何一格都还被贴身（`_sim_pin_escapable` = false）；
##   ③ 把"距 A = 2"的整圈堆上障碍（目标那格除外）⇒ 它这一回合只能停在环上；
##   ④ 目标放在"某个空环格的邻格"（距 A = 2）⇒ 它走过去贴住目标、打**贴身那一枪** = 真实 1 伤。
func _pick_arena() -> Dictionary:
	var A := Vector2i(-99, -99)
	var best_n := 0
	for c in battle.grid.all_cells():
		var ns: Array = []
		for n in battle.grid.neighbors(c):
			if battle.grid.in_bounds(n):
				ns.append(n)
		if ns.size() > best_n:
			best_n = ns.size()
			A = c
	if A.x == -99 or best_n < 4:
		return {}
	var ring: Array = []
	for n in battle.grid.neighbors(A):
		if battle.grid.in_bounds(n):
			ring.append(n)
	var occ_cells: Array = []
	for k in [0, 2, 4, 1]:
		if k < ring.size():
			occ_cells.append(ring[k])
	var free_ring: Array = []
	for c in ring:
		if not occ_cells.has(c):
			free_ring.append(c)
	var tgt := Vector2i(-99, -99)
	for w in free_ring:
		for n in battle.grid.neighbors(w):
			if n == A or not battle.grid.in_bounds(n) or occ_cells.has(n):
				continue
			if battle.grid.distance(A, n) != 2:
				continue
			tgt = n
			break
		if tgt.x != -99:
			break
	if tgt.x == -99:
		return {}
	var wall: Array = []
	for c in battle.grid.all_cells():
		if c == A or c == tgt or occ_cells.has(c) or ring.has(c):
			continue                      # 环上那几格留着（它这一回合就停在环上）
		if battle.grid.distance(A, c) <= 2:
			wall.append(c)
	return { "A": A, "pin": Vector2i(occ_cells[0]), "tgt": tgt, "wall": wall,
		"occ": occ_cells, "ring": ring, "free_ring": free_ring }
##   ⇒ 它**退不掉**（`_sim_pin_escapable` = false）⇒ 只能打"贴身那一枪"（射程压 1、伤害记 1）。
##   再把目标放在"某个可走格的旁边" ⇒ 它走过去贴住目标、打一枪 = **真实 1 伤** ⇒
##   这一盘就是"`d>1` 但**不能**记 0"的证据（一律记 0 会把这一枪砍掉）。
func _arm_pinned_shot() -> void:
	await _rebuild()
	GameState.ai_difficulty = 2
	var pick := _pick_arena()
	if pick.is_empty():
		print("PK|C/D|盘面没搭起来（找不到合适的起点/目标）")
		return
	var A: Vector2i = pick["A"]
	var pin_cell: Vector2i = pick["pin"]
	var tgt_cell: Vector2i = pick["tgt"]
	for c in (pick["wall"] as Array):
		battle.obstacles[c] = 3
	_spawn(GUNNER, DataRegistry.Faction.PLAYER, A, 20)
	_spawn(PINNER, DataRegistry.Faction.ENEMY, pin_cell, 15)
	var fillers := FILLERS
	var fi := 0
	for c in (pick["occ"] as Array):
		if c == pin_cell:
			continue
		_spawn(String(fillers[fi % fillers.size()]), DataRegistry.Faction.ENEMY, c, 16)
		fi += 1
	_spawn(NEAR, DataRegistry.Faction.ENEMY, tgt_cell, 16)
	print("PK|C/D 搭盘|起点 %s｜环 %s｜占位 %s（贴着它的 = %s）｜空环格 %s｜目标 %s（d=%d）｜障碍 %d 格" % [
		str(A), str(pick["ring"]).replace(" ", ""), str(pick["occ"]).replace(" ", ""),
		str(pin_cell), str(pick["free_ring"]).replace(" ", ""), str(tgt_cell),
		battle.grid.distance(A, tgt_cell), (pick["wall"] as Array).size()])
	for c in (pick["free_ring"] as Array):
		print("PK|C/D 距离|空环格 %s → 目标 %s 的格距=%d；→ 起点=%d（起点→目标=%d）" % [
			str(c), str(tgt_cell), battle.grid.distance(c, tgt_cell),
			battle.grid.distance(c, A), battle.grid.distance(A, tgt_cell)])
	# 逐层拆"门为什么是假"：贴不贴身 / 距离 / 视线 / `_cell_in_range` / 嘲讽
	for i2 in 3:
		await get_tree().process_frame
	var ai0 = battle._make_battle_ai()
	if ai0 != null:
		var snap0 := BattleSnapshot.collect(battle)
		var sim0 = ai0.build_state(snap0["descs"], snap0["occ"], snap0["gold"], snap0["grave"],
			snap0["obstacle"], snap0["bomb"], snap0["buff"], -1, snap0.get("rosters", {}), {},
			snap0.get("buff_owner", {}), snap0.get("deads", {}))
		var g0 = null
		var t0 = null
		for u in sim0.units:
			if u.hero_id == GUNNER:
				g0 = u
			elif u.hero_id == NEAR:
				t0 = u
		if g0 != null and t0 != null:
			for c in (pick["free_ring"] as Array):
				print("PK|C/D 拆门|从 %s：贴人=%s｜格距=%d｜视线挡=%s｜_cell_in_range=%s｜嘲讽允许=%s" % [
					str(c), str(ai0._sim_enemy_adjacent(sim0, g0, c)),
					battle.grid.distance(c, t0.cell), str(ai0._sim_path_blocked(sim0, c, t0.cell, g0)),
					str(ai0._cell_in_range(sim0, g0, c, t0.cell)),
					str(ai0._taunt_allows(sim0, g0, t0, c))])
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("PK|C/D|拿不到 AI")
		return
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var g2 = null
	var tg = null
	for u in sim.units:
		if u.hero_id == GUNNER:
			g2 = u
		elif u.hero_id == NEAR:
			tg = u
	if g2 == null or tg == null:
		print("PK|C/D|盘面没搭起来（g2=%s tg=%s）" % [str(g2 != null), str(tg != null)])
		return
	var d: int = battle.grid.distance(g2.cell, tg.cell)
	var hit: bool = ai._threat_can_hit(sim, g2, tg.cell, tg)
	var raw: float = ai._threat_hit_value(sim, g2, d, false, tg.cell, tg)
	var info := {}
	var inc: float = ai._incoming_total_on(sim, tg, tg.cell, info)
	var parts: Array[String] = []
	for row in (info.get("parts", []) as Array):
		var r: Array = row
		parts.append("%s=%.1f" % [String(r[0]), float(r[1])])
	var wcells: Array = ai._sim_walk_cells(sim, g2.cell, ai._threat_emove_next(sim, g2),
		(g2.skills as Array).has(DataRegistry.Skill.INFILTRATE))
	print("PK|C/D 盘面|火枪手@%s｜复仇者@%s｜目标@%s（d=%d）｜可走 %d 格（%s）" % [
		str(g2.cell), str(pin_cell), str(tg.cell), d, wcells.size(), str(wcells).replace(" ", "")])
	print("PK|C/D 判读|退得掉=%s（**false = 退不开**）｜门(_threat_can_hit)=%s｜裸值=%.1f｜**挨打合计=%.1f**（%s）" % [
		str(ai._sim_pin_escapable(sim, g2)), ("能打到" if hit else "够不到"), raw, inc,
		("、".join(parts) if parts.size() > 0 else "没有来源")])
	print("PK|C/D 结论|真实伤害 = **1 伤（走过去贴住、贴身那一枪）** ⇒ %s" % (
		"这一枪**真的存在**、不能一律记 0（探针账里正是 %.1f）" % inc if hit and inc > 0.5
		else "探针这一盘没搭成（门=%s、账=%.1f）" % [str(hit), inc]))

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
