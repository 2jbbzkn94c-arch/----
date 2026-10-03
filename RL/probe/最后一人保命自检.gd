extends Node
## 【2026-10-02·一次性探针·只读】用户口径：「AI 某个英雄下回合必死了，但他还是和往常一样参与战斗，
##   没有被保护起来。我觉得**除非能斩杀对方**，否则那个必死的英雄躲起来用走位苟一下，争取多几回合时间，
##   可能会翻盘」⇒ 本探针把这条口径做成对照：**同一块盘面**跑两次搜索（`LAST_MAN_W = 0` / `= 1`），
##   看那一手从"照常参战"变成"躲开"。
##
## 盘面（内部 0 基）：我方（AI）**只剩 1 条命**（快照带 `deads = {my: 2, foe: 0, line: 3}` ⇒ 再死一个就判负），
##   场上唯一单位 = 小阴影，血调到 **6**，站在 (2,2)：三个玩家单位都够得到它（`挨打合计 ≥ 6` ⇒ **必死**），
##   而左下角 (0,0) 一带是敌人下回合够不到的格子（躲过去就死不了）。它本回合**有能打的出手**（所以旧口径
##   一定会被"撤退过滤"把"只走位"丢掉 ⇒ 只能参战）。
##
## 打印：`_mine_lives()` / `_one_life_loss()`（这条命值多少终局分）· 两臂各自选出的计划 · 以及
##   「最后一人保命」那一笔的分数。输出：LM|… / LM|END

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("LM|盘面|我方 1 人（小阴影 血6 @(2,2)，**已阵亡 2 名 ⇒ 再死就判负**）｜玩家 2 人：巨剑(2,0)、嬉皮死神(0,2)（**故意不放暗域**：换位会让「安全格」也变危险，那样就没得躲了）")
	_arm(0.0, "改前（LAST_MAN_W = 0）")
	_arm(1.0, "改后（LAST_MAN_W = 1）")
	# 【2026-10-02·用户追加口径】「剩 3/2 条命的情况你别动，还没输就给我尽情战斗」⇒
	#   同一块盘面、只把"已阵亡 1 名"（= 还剩 **2 条命**）⇒ 键开着也必须**照常参战**。
	_arm(1.0, "剩 2 条命 · LAST_MAN_W = 1（应当照常参战）", 1)
	print("LM|END")
	get_tree().quit(0)

func _arm(w: float, tag: String, my_dead: int = 2) -> void:
	var descs: Array = []
	for r in [
		["ENEMY", "hero_15", Vector2i(2, 2), 6, "小阴影（我方最后一人）"],
		["PLAYER", "hero_12", Vector2i(2, 0), 24, "巨剑"],
		["PLAYER", "hero_30", Vector2i(0, 2), 20, "嬉皮死神"]]:
		var fn := DataRegistry.Faction.ENEMY if String(r[0]) == "ENEMY" else DataRegistry.Faction.PLAYER
		var d := _desc(fn, String(r[1]), r[2] as Vector2i, String(r[4]))
		d["hp"] = int(r[3])
		descs.append(d)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights({ "LAST_MAN_W": w })
	# ⚠️ 关键：快照带上阵亡数 ⇒ `_mine_lives()` = 判负线 3 − 已阵亡 2 = **1 条命**
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {}, -1, {}, {}, {},
		{ "my": my_dead, "foe": 0, "line": 3 })
	var me = sim.units[0]
	var inc := {}
	var inc_v: float = ai._incoming_total_on(sim, me, me.cell, inc)
	var parts: Array[String] = []
	for row in (inc.get("parts", []) as Array):
		var r0: Array = row
		parts.append("%s%.1f" % [String(r0[0]), float(r0[1])])
	if my_dead == 2 and w == 0.0:
		# 普查：这一回合它走得到的格子里，有几格"下回合死不了"（否则"躲"这件事本身无处可躲）
		var safe: Array[String] = []
		var wcells: Array = ai._sim_walk_cells(sim, me.cell, ai._threat_emove_next(sim, me), false)
		for c_v in wcells:
			var c: Vector2i = c_v
			var o2 := {}
			var v2: float = ai._incoming_total_on(sim, me, c, o2, false, true)
			if v2 < float(me.hp):
				safe.append("%s(%.1f)" % [str(c), v2])
		print("LM|能躲的格子|走得到 %d 格，其中**死不了**的有 %d 格：%s" % [
			wcells.size(), safe.size(), ("、".join(safe) if safe.size() > 0 else "**一格都没有**（躲也没用）")])
		var allv: Array[String] = ["%s=%.1f" % [str(me.cell), inc_v]]
		for c_v in wcells:
			var c: Vector2i = c_v
			allv.append("%s=%.1f" % [str(c), float(ai._incoming_total_on(sim, me, c, {}, false, true))])
		print("LM|逐格挨打合计|%s" % "、".join(allv))
		print("LM|底账|我方还剩 %d 条命｜丢一条命值 **%.0f 分**｜小阴影站在 (2,2) 的挨打合计 = **%.1f**（%s）⇒ %s" % [
			int(ai._mine_lives(sim)), float(ai._one_life_loss(sim)), inc_v, "＋".join(parts),
			("**下回合必死**" if inc_v >= float(me.hp) else "还死不了")])
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var steps: Array[String] = []
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var nm := "?"
		if idx >= 0 and idx < sim.units.size() and sim.units[idx] != null:
			nm = String(sim.units[idx].name)
		var atk := int(a.get("atk", -1))
		var tname := "—"
		if atk >= 0 and atk < sim.units.size() and sim.units[atk] != null:
			tname = String(sim.units[atk].name)
		steps.append("%s：move=%s｜atk=%s" % [nm, str(a.get("move")), ("打 " + tname) if atk >= 0 else ("拆障碍" if atk == -2 else "不出手")])
	print("LM|%s|计划 %d 步：%s" % [tag, plan.size(), ("；".join(steps) if steps.size() > 0 else "（空）")])
	# 【关键对照】手工造两个末态，直接比较完整 `_evaluate` —— 判"是评分没算进去"还是"搜索没找到"
	if my_dead == 2 and w == 1.0:
		var idx_me := 0
		var idx_jian := 1
		var a_safe := sim.clone()
		ai._apply(a_safe, idx_me, { "move": Vector2i(0, 3), "atk": -1 })
		var a_fight := sim.clone()
		ai._apply(a_fight, idx_me, { "move": Vector2i(2, 3), "atk": idx_jian })
		for pair in [[a_safe, "躲到 (0,3)（不还手）"], [a_fight, "走到 (2,3) 打 巨剑"]]:
			var sm = pair[0]
			var inc_s := ai._incoming_incs(sm)
			print("LM|手工末态|%s ⇒ `_evaluate` = **%.1f**｜挨打合计 = %.1f（血 %d）｜最后一人保命 = %.1f" % [
				String(pair[1]), float(ai._evaluate(sm, true)),
				float(inc_s[0]), int(sm.units[0].hp), float(ai._last_man_fold(sm, inc_s))])
	# 【用户追问】「会考虑走位让必死之人下回合**活着**吗？而不是单纯的跑」⇒ 把"跑得最远的那一格"
	#   与"它实际选的那一格"并排打出来（跑最远 ≠ 活得下来）。
	if my_dead == 2:
		var far_cell: Vector2i = me.cell
		var far_d := -1
		var wcells2: Array = ai._sim_walk_cells(sim, me.cell, ai._threat_emove_next(sim, me), false)
		for c_v in wcells2:
			var c2: Vector2i = c_v
			var dd: int = ai.grid.distance(me.cell, c2)
			if dd > far_d:
				far_d = dd
				far_cell = c2
		var o_far := {}
		var v_far: float = ai._incoming_total_on(sim, me, far_cell, o_far, false, true)
		var land: Vector2i = me.cell
		for st in plan:
			var a3: Dictionary = st["action"]
			if a3.get("move") != null:
				land = Vector2i(a3["move"])
		var o_l := {}
		var v_l: float = ai._incoming_total_on(sim, me, land, o_l, false, true)
		print("LM|★走位 vs 单纯跑★|%s：**跑得最远的是 %s**（挨打合计 %.1f ⇒ %s）｜**它实际选了 %s**（挨打合计 %.1f ⇒ %s）" % [
			tag, str(far_cell), v_far, ("照样死（≥ 血 %d）" % int(me.hp) if v_far >= float(me.hp) else "能活"),
			str(land), v_l, ("**下回合会被打死**" if v_l >= float(me.hp) else "**下回合活着** ✓")])
	var attacked := false
	for st in plan:
		if int((st["action"] as Dictionary).get("atk", -1)) >= 0:
			attacked = true
	print("LM|%s|★%s★｜那一笔「最后一人保命」= %.0f 分" % [tag,
		("**照常参战**（本回合出手了）" if attacked else "**躲开/不出手**（保命优先）"),
		float(ai._last_man_fold(sim, ai._incoming_incs(sim)))])

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
