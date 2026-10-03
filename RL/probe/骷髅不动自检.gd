extends Node
## 【2026-10-02·一次性探针·只读】用户实机（[战局转储] + 决策日志）问：
##   「**为什么这次 AI 都不动骷髅就结束了**」—— 日志里写着「召唤物先单独定 **2** 手」，
##   可计划只有 2 步（烈焰祭司 / 共鸣者）、两只骷髅一个步骤都没有。
##
## 盘面 = 用户那份转储逐格复刻（**界面口径 − 1 = 内部 0 基**）：
##   AI（ENEMY）：死灵法师 hero_33@(0,2) 18血 · 烈焰祭司 hero_19@(1,1) 13血 · 共鸣者 hero_47@(2,2) 6血[中毒]
##                骷髅兵 summon_skeleton@(0,3) 1血 · @(0,1) 1血（都在场上、都没动）
##   玩家（PLAYER）：毒蛇淑女 hero_03@(3,2) 17血 · 风语者 hero_43@(1,2) 10血 · 红帽 hero_40@(2,1) 12血
##   障碍 = [(2,3)]（转储里 `障碍=[(3, 4)]`）
##
## 读数（三样并排）：
##   ① `last_summon_pre_n` / `last_summon_late_n`（搜索自己报"先定了几手"）
##   ② 返回的计划里**有没有召唤物的步骤**
##   ③ `search()` 跑完后**传进去那个 sim** 里骷髅的 `moved/attacked` 标志
##      —— ③ 为 true 而 ② 为 false ⇒ **搜索里它们"已经出手了"（分算了）、计划里却没有这一步（实机回放不会动）**。
##
## 用**噩梦档**（difficulty 3 ⇒ 走 fork `RL/ai/AI_Battle.gd`，与用户那份 噩梦1 同一份引擎、只差思考上限）。
## 输出：SK|… / SK|END

const SKEL := "summon_skeleton"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _rebuild()
	GameState.ai_difficulty = 3
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(3, 2), 17)  # 毒蛇淑女
	_spawn("hero_43", DataRegistry.Faction.PLAYER, Vector2i(1, 2), 10)  # 风语者
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(2, 1), 12)  # 红帽
	battle.obstacles[Vector2i(2, 3)] = battle.OBSTACLE_DUR
	_spawn("hero_19", DataRegistry.Faction.ENEMY, Vector2i(1, 1), 13)   # 烈焰祭司
	var necro = _spawn("hero_33", DataRegistry.Faction.ENEMY, Vector2i(0, 2), 18)   # 死灵法师
	var echo = _spawn("hero_47", DataRegistry.Faction.ENEMY, Vector2i(2, 2), 6)   # 共鸣者（中毒）
	if echo != null:
		echo.add_status(StatusDB.POISON)
	# ⚠️ 召唤必须在**玩家已就位之后**（真实时序：风语者上一回合就站在 (1,2)、骷髅是它自己回合开场召的）
	#   ⇒ 落点才会是转储里的 (0,3) 与 (0,1)。
	if necro != null:
		battle._summon_skeletons(necro)
	var skel_cells: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.hero_id == SKEL:
			skel_cells.append(str(u.cell))
	print("SK|召唤|真实召唤链造出 %d 只骷髅：%s（用户那份转储是 (0,3) 与 (0,1)）" % [
		skel_cells.size(), "、".join(skel_cells)])
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var n_skel := 0
	for d in (snap["descs"] as Array):
		if String(d.get("hero", "")) == SKEL:
			n_skel += 1
	print("SK|盘面|AI %d 人（其中骷髅 %d）｜玩家 %d 人｜障碍 %d 格" % [
		(snap["descs"] as Array).size() - 3, n_skel, 3, battle.obstacles.size()])
	var ai = battle._make_battle_ai()
	if ai == null:
		print("SK|拿不到 AI")
		print("SK|END")
		get_tree().quit(0)
	ai.difficulty = GameState.ai_difficulty
	ai.log_decisions = false
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var before: Array[String] = []
	for u in sim.units:
		if u.hero_id == SKEL:
			before.append("%s@%s" % [String(u.name), str(u.cell)])
	print("SK|搜索前|骷髅：%s（都没有 moved/attacked）" % "、".join(before))
	# ⚠️ 关键取证：`_ai_unit_count(sim)` 就是抬头行那个「N 个单位」；用户那份日志里它写 **3**（场上明明 5 个）
	#   ⇒ 打印**搜索前后**的它 + 每个单位的 fn/alive，看搜索有没有动过 `sim.units`。
	print("SK|搜索前|`_ai_unit_count`=%d（用户那份日志抬头写 3）｜sim.units=%d" % [
		int(ai._ai_unit_count(sim)), sim.units.size()])
	for u in sim.units:
		print("SK|搜索前·单位|%s[%s] fn=%d alive=%s moved=%s attacked=%s" % [
			String(u.name), String(u.hero_id), int(u.fn), str(u.alive), str(u.moved), str(u.attacked)])
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	print("SK|搜索后|`_ai_unit_count`=%d｜sim.units=%d" % [int(ai._ai_unit_count(sim)), sim.units.size()])
	print("SK|搜索后|耗时 %.1fs｜`last_summon_pre_n`=%d（先单独定的手数）· `last_summon_late_n`=%d（打不到⇒等英雄走完）" % [
		float(ms) / 1000.0, int(ai.last_summon_pre_n), int(ai.last_summon_late_n)])
	# ③ 传进去的那份 sim 现在长什么样（搜索会就地 `_apply` 预置的那几手）
	for u in sim.units:
		if u.hero_id == SKEL:
			print("SK|离场盘面|骷髅 %s@%s ⇒ moved=%s attacked=%s" % [
				String(u.name), str(u.cell), str(u.moved), str(u.attacked)])
	# ② 返回的计划里有谁
	var steps: Array[String] = []
	var skel_steps := 0
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var hid := ""
		var nm := "?"
		if idx >= 0 and idx < sim.units.size() and sim.units[idx] != null:
			hid = String(sim.units[idx].hero_id)
			nm = String(sim.units[idx].name)
		if hid == SKEL:
			skel_steps += 1
		steps.append("%s(move=%s atk=%s)" % [nm, str(a.get("move")), str(a.get("atk"))])
	print("SK|返回计划|%d 步：%s" % [plan.size(), ("、".join(steps) if steps.size() > 0 else "（空）")])
	# ④ 通用判据：**搜索认为"它这一回合动过/出过手"的单位，计划里是不是真有它的步骤** ——
	#   两边不一致就是"分算了、实机不做"的幽灵（骷髅那一支正是这么丢的）。
	var in_plan := {}
	for st in plan:
		in_plan[int(st["idx"])] = true
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var acted: bool = bool(u.moved) or bool(u.attacked)
		var has: bool = in_plan.has(i)
		if acted != has:
			print("SK|★幽灵★|%s@%s：搜索盘上 moved=%s attacked=%s，可是计划里**%s**" % [
				String(u.name), str(u.cell), str(u.moved), str(u.attacked),
				("有它的步骤" if has else "没有它的步骤 ⇒ 分算了、实机不会做")])
		else:
			print("SK|对账|%s@%s：moved=%s attacked=%s ↔ 计划%s ✓" % [
				String(u.name), str(u.cell), str(u.moved), str(u.attacked),
				("有步骤" if has else "没步骤（两边界一致）")])
	print("SK|★判定★|召唤物的步骤 = **%d 个**%s" % [skel_steps,
		" ⇒ **分算了、计划里没有**（实机回放不会动骷髅）" if skel_steps == 0 and int(ai.last_summon_pre_n) > 0
		else (" ⇒ 一致（计划里带着它们的手）" if skel_steps > 0 else " ⇒ 搜索没给它们定手（另一回事）")])
	print("SK|———|下面第二盘：把「英雄没事可干、骷髅能收人头」摆出来（逼出「全员原地」那套阵型）")
	await _arm_stay()
	print("SK|———|第三盘：把三个英雄的移动力压成 0（`move_buff`）⇒ 只有「全员原地」那一套阵型 ⇒ 逼出「保送」分支")
	await _arm_no_move()
	print("SK|END")
	get_tree().quit(0)

## 第三盘（**定向复现用户那一局**）：英雄走不动 ⇒ 阶段 1 只剩「全员原地」那一套阵型；
##   而它在 `SUMMON_PREPLAN` 开着时 path 不为空（= 骷髅那两步）⇒ 触发"保送"分支**重建一套 path=[] 的**
##   ⇒ 若它赢了：搜索盘上骷髅已出手（分算了）、计划里却没有它们的步骤 ⇒ 用户看到的"骷髅不动"。
func _arm_no_move() -> void:
	await _rebuild()
	GameState.ai_difficulty = 3
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(3, 2), 17)
	_spawn("hero_43", DataRegistry.Faction.PLAYER, Vector2i(1, 2), 10)
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(2, 1), 12)
	battle.obstacles[Vector2i(2, 3)] = battle.OBSTACLE_DUR
	var h19 = _spawn("hero_19", DataRegistry.Faction.ENEMY, Vector2i(1, 1), 13)
	var necro = _spawn("hero_33", DataRegistry.Faction.ENEMY, Vector2i(0, 2), 18)
	var echo = _spawn("hero_47", DataRegistry.Faction.ENEMY, Vector2i(2, 2), 6)
	if echo != null:
		echo.add_status(StatusDB.POISON)
	for h in [h19, necro, echo]:                    # 英雄移动力压成 0（只此一盘、只为逼出那条分支）
		if h != null:
			h.move_buff = -9
	if necro != null:
		battle._summon_skeletons(necro)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("SK|三盘|拿不到 AI")
		return
	ai.difficulty = GameState.ai_difficulty
	ai.log_decisions = false
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var mv: Array[String] = []
	for u in sim.units:
		if u.fn == DataRegistry.Faction.ENEMY and not DataRegistry.summons.has(u.hero_id):
			mv.append("%s 移%d" % [String(u.name), int(u.emove)])
	print("SK|三盘·盘面|英雄移动力：%s" % "、".join(mv))
	print("SK|三盘·搜索前|`_ai_unit_count`=%d" % int(ai._ai_unit_count(sim)))
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	print("SK|三盘·搜索后|`_ai_unit_count`=%d（场上其实 5 人）｜耗时 %.1fs" % [
		int(ai._ai_unit_count(sim)), float(ms) / 1000.0])
	var steps: Array[String] = []
	var skel_steps := 0
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var nm := "?"
		if idx >= 0 and idx < sim.units.size() and sim.units[idx] != null:
			nm = String(sim.units[idx].name)
			if String(sim.units[idx].hero_id) == SKEL:
				skel_steps += 1
		steps.append("%s(move=%s atk=%s)" % [nm, str(a.get("move")), str(a.get("atk"))])
	print("SK|三盘·计划|%d 步：%s" % [plan.size(), ("、".join(steps) if steps.size() > 0 else "（空）")])
	for u in sim.units:
		if u.hero_id == SKEL:
			print("SK|三盘·离场盘面|骷髅 %s@%s alive=%s ⇒ moved=%s attacked=%s" % [
				String(u.name), str(u.cell), str(u.alive), str(u.moved), str(u.attacked)])
	print("SK|三盘★判定★|召唤物步骤 = **%d 个** ⇒ %s" % [skel_steps,
		"**幽灵**（搜索里它们出手了、计划里没有 ⇒ 实机不会动）" if skel_steps == 0
		else "一致（计划里带着它们的手）"])

## 第二盘（定向复现）：**英雄没事可干、骷髅能收人头** ⇒ 最优计划很可能是"英雄全原地 + 骷髅出手"，
##   而"英雄全原地"那套阵型在 SFUMMON_PREPLAN 开着时 path 不为空 ⇒ 触发"保送"分支**重建一套 path=[] 的**
##   ⇒ 若它赢了：搜索盘上骷髅已出手（分算了）、计划里却没有它们的步骤 ⇒ 幽灵。
func _arm_stay() -> void:
	await _rebuild()
	GameState.ai_difficulty = 3
	_spawn("hero_43", DataRegistry.Faction.PLAYER, Vector2i(1, 2), 3)    # 风语者（3 血，骷髅一刀 2、两只够收）
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(4, 6), 17)   # 远远的
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(4, 5), 12)
	var necro = _spawn("hero_33", DataRegistry.Faction.ENEMY, Vector2i(0, 2), 18)
	_spawn("hero_19", DataRegistry.Faction.ENEMY, Vector2i(0, 6), 13)    # 离谁都远 ⇒ 走也白走
	var echo = _spawn("hero_47", DataRegistry.Faction.ENEMY, Vector2i(0, 5), 6)
	if echo != null:
		echo.add_status(StatusDB.POISON)
	if necro != null:
		battle._summon_skeletons(necro)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("SK|二盘|拿不到 AI")
		return
	ai.difficulty = GameState.ai_difficulty
	ai.log_decisions = false
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var steps: Array[String] = []
	var skel_steps := 0
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var nm := "?"
		if idx >= 0 and idx < sim.units.size() and sim.units[idx] != null:
			nm = String(sim.units[idx].name)
			if String(sim.units[idx].hero_id) == SKEL:
				skel_steps += 1
		steps.append("%s(move=%s atk=%s)" % [nm, str(a.get("move")), str(a.get("atk"))])
	print("SK|二盘|耗时 %.1fs｜pre_n=%d late_n=%d｜计划 %d 步：%s" % [
		float(ms) / 1000.0, int(ai.last_summon_pre_n), int(ai.last_summon_late_n), plan.size(),
		("、".join(steps) if steps.size() > 0 else "（空）")])
	for u in sim.units:
		if u.hero_id == SKEL:
			print("SK|二盘·离场盘面|骷髅 %s@%s ⇒ moved=%s attacked=%s" % [
				String(u.name), str(u.cell), str(u.moved), str(u.attacked)])
	print("SK|二盘★判定★|召唤物步骤 = **%d 个**｜pre_n = %d ⇒ %s" % [skel_steps, int(ai.last_summon_pre_n),
		"**幽灵复现**（搜索里它们出手了、计划里没有 ⇒ 实机不会动）" if skel_steps == 0 and int(ai.last_summon_pre_n) > 0
		else ("一致" if skel_steps > 0 else "搜索没给它们定手")])

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
