extends Node
## 【2026-10-02·一次性探针·只读·用户报「这个 (4,2) 是 AI 的碑，他为什么说不是合法落点」】
##
## 验什么：**"指定的落点 = 本方墓碑格"时，落位到底认不认**（认 = 顶碑落位/阵亡原地补位 ——
##   手册落位 `_try_place_sub()`、UI 高亮、`_sub_legal_cells_for_ai()` 三处都把它写成合法落点）。
##
## 病灶（改前）：`_place_enemy_sub()` 里那道"指定落点"的门写成
##   `not occupancy.has(c) and not graves.has(c) and _sub_legal_cells_for_ai().has(c)`
##   —— 前两句要求"这一格不是墓碑"，第三句却要求"它在本方墓碑格清单里"⇒ **自相矛盾**：
##   只要是碑格就永远进不来，还会打出一句**错的**日志「指定的 X 不在合法落点里」。
##   用户日志里那一幕（动态替补挑中我方碑格 ⇒ 被判非法 ⇒ 改落出生区）就是它。
##
## 两条臂（同一盘面，只换"那两座碑是谁的"）：
##   臂 A **预设替补席 + 斩杀撤人指定格**（`_forced_sub_hero` / `_forced_sub_cell` 那条路）
##        ⇒ 期望：替补**落在指定的碑格上**、碑被消耗（改前：被否 ⇒ 退回默认规则的第一座碑）
##   臂 B **动态替补池**（判据①"能斩杀"自己挑的落点 = 碑格 —— 就是用户那一幕）
##        ⇒ 期望：落点 == 挑中的那一格（改前：被否 ⇒ 退回默认规则的第一座碑）
##
## 盘面（**内部 0 基**坐标）刻意摆成"结果唯一、不靠打分"：
##   · 远碑 (0,6)：**离目标 9 格**（> 任何收尾候选的 移动+射程 上限 7）⇒ "从这一格收不掉"，
##     于是判据①只会挑近碑；而默认规则 `_free_sub_cell_for()`（先挑第一座本方碑）**会**挑它 ⇒
##     两种行为（"指定格照办" vs "被否退回默认"）落点必然不同 ⇒ 这条断言能真正分辨改前改后。
##   · 近碑 (4,2)：**贴着目标**，是唯一能一击收掉它的落点。
##   · (4,3) 玩家方一个 4 血目标（从 (4,2) 一步/原地就能收掉）。
##   · `SUB_JOIN_RULE` 的缓存**手动置 0（关）**：规则 C 会在"落点被否"之后二次改格 ⇒ 关掉它，
##     两种行为才分得开（规则 C 本身不是本次要验的东西）。
##
## 输出：GRV|CFG / GRV|臂… / GRV|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3          # 噩梦（走 fork；权重里 SUB_JOIN_RULE=1，本探针会手动关掉）
	print("GRV|CFG|噩梦｜盘面：目标在 (0,0)（内部坐标）、血 6｜近碑 = 距目标 1 格的那一格｜远碑 = 距目标最远的那一格")
	var a := await _arm("A_预设席指定格", false)
	var b := await _arm("B_动态池挑的格", true)
	print("GRV|END|A=%s B=%s" % [("PASS" if a else "FAIL"), ("PASS" if b else "FAIL")])
	get_tree().quit(0)

## dynamic = true ⇒ 走"动态替补池"那条（没有预设替补席，落点由 `_dynamic_sub_pick()` 自己挑）；
## dynamic = false ⇒ 走"预设替补席 + 斩杀撤人指定格"那条（`_forced_sub_hero` + `_forced_sub_cell`）
func _arm(tag: String, dynamic: bool) -> bool:
	await _rebuild()
	# 目标放**中场**（对角上那种"边角格"AI 的走位模型可能算不通 —— 初版踩过：目标一进角，
	#   所有候选的 `approach_dist` 都成 `INF_DIST(536870912)` ⇒ 判据① 恒返回 {}）。
	var tgt_cell := Vector2i(2, 4)
	# 近碑 = 与目标格距 1、又不是出生区格的那一格；远碑 = 角落 (0,0)，并且**用障碍把它围死**
	#   （这样它"走不出去" ⇒ 判据① 绝不会挑它；而"被否之后退回默认规则"照样会挑它 ⇒ 两种行为分得开）。
	var far := Vector2i(0, 0)
	var near := Vector2i(-99, -99)
	for x in 5:
		for y in 7:
			var c := Vector2i(x, y)
			if battle.grid.distance(c, tgt_cell) == 1 and not battle._in_spawn_cell(c, DataRegistry.Faction.ENEMY) \
					and not battle.occupancy.has(c) and not battle.graves.has(c):
				near = c
				break
		if near.x != -99:
			break
	if near.x == -99:
		near = Vector2i(2, 3)
	var far_d: int = battle.grid.distance(far, tgt_cell)
	# 目标血 3：判据①"一击就能收"的候选很多（长剑/烛火/小阴影…）⇒ 它必然挑得出落点。
	_spawn("hero_30", DataRegistry.Faction.PLAYER, tgt_cell, 3)   # 嬉皮死神，压到 3 血
	battle.player_roster = ["hero_24", "hero_45"]   # 长腿(7)/超远射程(99)那两位当"本局已出现"⇒ 不进动态池
	battle.obstacles[Vector2i(1, 0)] = 1            # 把角落 (0,0) 围死（它只剩这两个邻格）
	battle.obstacles[Vector2i(0, 1)] = 1
	# ⚠️ **先插远碑**：默认规则 `_free_sub_cell_for()` 与"判据①的候选格顺序"都按插入顺序取第一座
	#   ⇒ 先插远碑，"被否之后退回默认"才是落在远碑上（与"指定/挑中的近碑"分得开）。
	battle.graves[far] = { "hero": "hero_13", "fn": DataRegistry.Faction.ENEMY }
	battle.graves[near] = { "hero": "hero_11", "fn": DataRegistry.Faction.ENEMY }
	GameState.enemy_recipe = { "dynamic_bench": true } if dynamic else {}
	battle.enemy_roster = [] if dynamic else ["hero_40"]
	battle.sub_by_search = false          # 别开线程（本探针只看"落点认不认"）
	battle._sub_join_rule_cache = 0       # 规则 C 关（见文件头）
	battle._pending_enemy_sub = 1
	if not dynamic:
		battle._forced_sub_hero = "hero_40"
		battle._forced_sub_cell = near   # 指定落点 = 我方碑格（本次要验的就是它）
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var legal: Array = battle._sub_legal_cells_for_ai()
	var in_legal := legal.has(near)
	var pick := Vector2i(-99, -99)
	var pick_hid := ""
	if dynamic:
		# 诊断（只打印）：判据①（`_sub_kill_scan`）自己算出来的是什么（它才是"挑哪一格"的那把尺）
		var cf: Array = battle._finish_hero_pool(battle._dynamic_sub_candidates())
		var sk: Dictionary = battle._sub_kill_scan(cf, legal)
		print("GRV|%s|诊断|近碑 %s（距目标 %d）｜远碑 %s（距目标 %d，四周被障碍围死）｜收尾候选 %d 人｜判据①给的落点=%s" % [
			tag, _txt(near), battle.grid.distance(near, tgt_cell), _txt(far), far_d, cf.size(),
			(DataRegistry.cell_txt(sk.get("cell", Vector2i(-99, -99))) if not sk.is_empty() else "（{} = 没算出斩杀）")])
		# 那两座碑"走不走得通"（`approach_dist` 就是判据①的够不够得着那把尺；INF_DIST = 走不通）
		var ai2 = battle._make_battle_ai()
		if ai2 != null:
			var snap2 := BattleSnapshot.collect(battle)
			var sim2 = ai2.build_state(snap2["descs"], snap2["occ"], snap2["gold"], snap2["grave"],
					snap2["obstacle"], snap2["bomb"], snap2["buff"], -1, snap2.get("rosters", {}), {},
					snap2.get("buff_owner", {}), snap2.get("deads", {}))
			var t2 = null
			for su in sim2.units:
				if su.alive and su.fn != DataRegistry.Faction.ENEMY:
					t2 = su
					break
			if t2 == null:
				print("GRV|%s|诊断·模拟盘里找不到玩家目标（快照/建局有问题）" % tag)
			else:
				print("GRV|%s|诊断·走位|从近碑到目标=%d｜从远碑到目标=%d（%d = INF_DIST 走不通）｜模拟目标血=%.0f" % [
					tag, ai2.approach_dist(sim2, near, t2.cell), ai2.approach_dist(sim2, far, t2.cell),
					int(ai2.INF_DIST), float(t2.hp)])
		var dyn: Dictionary = await battle._dynamic_sub_pick()
		pick = dyn.get("cell", Vector2i(-99, -99))
		pick_hid = String(dyn.get("id", ""))
	var before := {}
	for u in battle.units:
		before[u.get_instance_id()] = true
	await battle._place_enemy_sub()
	for i in 2:
		await get_tree().process_frame
	var landed := Vector2i(-99, -99)
	var landed_hid := ""
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and not before.has(u.get_instance_id()):
			landed = u.cell
			landed_hid = String(u.hero_id)
			break
	var near_eaten := not battle.graves.has(near)
	# 挑中的那一格（动态那条）/ 指定的那一格（预设那条），一律换算成"内部坐标"再比
	var want := near
	var want_txt := "指定 " + _txt(near)
	if dynamic:
		want = pick
		want_txt = "挑中 " + _txt(pick) + (" " + _name_of(pick_hid) if pick_hid != "" else "")
	print("GRV|%s|碑格 %s 在合法落点里=%s｜合法落点=%s｜%s｜实际落=%s（%s）｜近碑被消耗=%s" % [
		tag, _txt(near), str(in_legal), str(legal), want_txt,
		_txt(landed), _name_of(landed_hid), str(near_eaten)])
	var ok := (landed == want) and near_eaten
	if dynamic:
		ok = ok and (pick == near)     # 判据①本来就该挑"唯一能收掉目标"的近碑
	print("GRV|%s|判定|%s（期望：碑格就是合法落点、指定/挑中哪一格就得落哪一格；改前是「被否 ⇒ 落远碑 %s」）" % [
		tag, ("PASS" if ok else "FAIL"), _txt(far)])
	return ok

func _txt(c: Vector2i) -> String:
	return "%s(内 %d,%d)" % [DataRegistry.cell_txt(c), c.x, c.y]

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

func _name_of(v) -> String:
	if v is String:
		var d = DataRegistry.get_hero(String(v))
		return String(d.display_name) if d != null else String(v)
	if v != null and is_instance_valid(v):
		return String(v.display_name)
	return "（无）"
