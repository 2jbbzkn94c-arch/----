extends Node
## 【2026-09-26 一次性探针】白游侠"为什么不退一步再打"自检 —— 跑完即退，**不改任何生产代码**。
##
## 用户问题（附截图 + AI 决策日志）：
##   「白游侠为什么不往后退，然后攻击啊」
##   日志原文：白游侠 = 敲掉障碍 (0, 3)（清路）；没选的那一手 = 在 (1, 2) 原地打 黄金矿工（约 1 伤），
##   换它会少 2.1 分 —— 「自己这边要掉血」；分差明细 ③血量账 +2.2 · ④集火frac² -0.1。
##
## 盘面（按截图 + 日志反推成 **AI 回合开始那一刻**）：
##   敌方(AI)：白游侠 hero_10(1,2)19 · 复仇者 hero_23(2,2)20/26【嘲】· 锤头鲨 hero_37(3,2)20
##   我方(玩家)：烈焰祭司 hero_19(1,3)18 · 圣光 hero_22(2,3)19/21【嘲·带盾】· 黄金矿工 hero_42(3,3)21/18
##   障碍：酒桶 (0,2)(0,3)(4,2)(4,3)
##   ⚠️ 截图是**玩家回合**，所以面板上的 黄金矿工5 / 圣光3 含「烈焰祭司光环 +1」；
##      AI 回合开始时那 +1 已过期 ⇒ 面板值只作为**声明的 eatk** 用（探针两种都跑，见下）。
##
## 本探针回答四件事：
##   ① 白游侠这一回合的**全部候选**（含"退到哪再打谁"）—— 先看"退一步再打"这条线到底生成了没有；
##   ② 可达格逐格：退到 (1,1)/(2,1) 之后**能不能打到圣光**、伤害多少、还贴不贴身（远程贴身 = 攻压 1 + 技能失效）；
##   ③ 真跑 `search()`：与用户日志对照（计划里白游侠是不是也在敲障碍）；
##   ④ **反事实比分**：在同一局面（计划里白游侠那一步之前）逐个候选 `_apply` + `_evaluate` +
##      `_eval_breakdown` 差项 ⇒ 直接回答"退一步再打"到底值多少分、是被算出来更差还是压根没进候选；
##   ⑤ 消融：把 `TWO_PHASE_INNER` / `TWO_PHASE_LAYOUTS` 放宽、以及退回单阶段 `SEARCH_MODE=0` 各搜一次
##      ⇒ 若放宽后它就"退着打"了，说明是**搜索漏斗漏线**，不是评分口径问题。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag bx -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/白游侠后退自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const CAP_MS := 30000

var _grid: HexGrid
var _nm: Dictionary = {}
var _ai = null
var _sim = null
var _bx := -1     # 白游侠在 sim.units 里的下标

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|SEARCH_MODE=%s|BEAM=%s|INNER=%s|LAYOUTS=%s|DEDUP=%s|FUNNEL_DIVERSITY=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), str(_nm.get("BEAM", 0)),
		str(_nm.get("TWO_PHASE_INNER", 0)), str(_nm.get("TWO_PHASE_LAYOUTS", 0)),
		str(_nm.get("TWO_PHASE_DEDUP", 0)), str(_nm.get("FUNNEL_DIVERSITY", "-"))])
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_10", Vector2i(1, 2), "白游侠", { "hp": 19 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_23", Vector2i(2, 2), "复仇者",
		{ "hp": 20, "eatk": 3 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_37", Vector2i(3, 2), "锤头鲨",
		{ "hp": 20, "eatk": 3 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_19", Vector2i(1, 3), "烈焰祭司", { "hp": 18 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_22", Vector2i(2, 3), "圣光",
		{ "hp": 19, "eatk": 3, "shield": true }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_42", Vector2i(3, 3), "黄金矿工",
		{ "hp": 21, "max_hp": 18, "eatk": 5 }))
	var obs := { Vector2i(0, 2): true, Vector2i(0, 3): true, Vector2i(4, 2): true, Vector2i(4, 3): true }
	var built := _build(descs, obs)
	_ai = built["ai"]
	_sim = built["sim"]
	_bx = 0
	for i in _sim.units.size():
		var u = _sim.units[i]
		if String(u.hero_id) == "hero_10":
			_bx = i
	print("PROBE|盘面|（eatk 按截图面板声明：黄金矿工5/圣光3 含烈焰祭司光环；AI 回合开始时那 +1 可能已过期）")
	for i in _sim.units.size():
		var u2 = _sim.units[i]
		print("PROBE|盘面|%s%s@%s|atk=%d eatk=%d hp=%d/%d|emove=%d 射程=%d|贴身=%s|池倍率=%.3f|嘲讽=%s 盾=%s" % [
			("AI " if u2.fn == DataRegistry.Faction.ENEMY else "玩家"), String(u2.name), str(u2.cell),
			int(u2.atk), int(u2.eatk), int(u2.hp), int(u2.max_hp), int(u2.emove), int(u2.atk_range),
			str(_ai._sim_pinned_ranged(_sim, u2)), float(_ai._incoming_pool_mult(u2)),
			str((u2.skills as Array).has(DataRegistry.Skill.TAUNT)), str(bool(u2.shield))])
	var bx = _sim.units[_bx]
	# ② 可达格 × 能打谁（含"退开之后还贴不贴身"）
	print("PROBE|白游侠|当前 cell=%s eatk=%d 贴身=%s 射程=%d" % [
		str(bx.cell), int(bx.eatk), str(_ai._sim_pinned_ranged(_sim, bx)), int(bx.atk_range)])
	var reach: Array = _ai._move_cells(_sim, bx).keys()
	for c in reach:
		var cc: Vector2i = c
		var tns: Array = []
		for ti in _ai._valid_targets(_sim, bx, cc):
			var tu = _sim.units[int(ti)]
			tns.append("%s(约%d伤)" % [String(tu.name), int(_ai._hit_after_target_mods(_sim, tu, tu.cell, float(bx.eatk)))])
		print("PROBE|可达格|%s|该格贴身=%s|能打=%s" % [
			str(cc), str(_ai._sim_enemy_adjacent(_sim, bx, cc)), str(tns)])
	# ②b 决定性实验：`_valid_targets()` 用的是**移动前**的占位表 ⇒ 射手**自己原来的格子**可能挡住自己的射线。
	#    真实规则里"先走到 (1,1)、再开火"时那一格已经空了。这里在探针里**临时**把射手挪过去
	#    （改 sim.occ + u.cell，跑完还原），看退开后到底能不能打到人 —— 不改任何生产代码。
	for c2 in reach:
		var ccc: Vector2i = c2
		var old_cell: Vector2i = bx.cell
		_sim.occ.erase(old_cell)
		bx.cell = ccc
		_sim.occ[ccc] = bx
		var tns2: Array = []
		for ti6 in _ai._valid_targets(_sim, bx, ccc):
			var tu2 = _sim.units[int(ti6)]
			tns2.append("%s(约%d伤)" % [String(tu2.name),
				int(_ai._hit_after_target_mods(_sim, tu2, tu2.cell, float(bx.eatk)))])
		bx.cell = old_cell
		_sim.occ.erase(ccc)
		_sim.occ[old_cell] = bx
		print("PROBE|退开后能打(占用已更新)|%s|%s" % [str(ccc), str(tns2)])
	# ① 全部候选（这一步是"生成层"的证据）
	var cands: Array = _ai._actions_for(_sim, _bx)
	print("PROBE|候选数|%d" % cands.size())
	for combo in cands:
		var mc: Variant = combo.get("move")
		var ti2 := int(combo.get("atk", -1))
		var tn2 := "-"
		if ti2 >= 0 and ti2 < _sim.units.size():
			tn2 = String(_sim.units[ti2].name)
		var landed: Vector2i = bx.cell if mc == null else mc
		print("PROBE|候选|move=%s atk=%s|落点贴身=%s|障碍=%s" % [
			("原地" if mc == null else str(landed)), tn2,
			str(_ai._sim_enemy_adjacent(_sim, bx, landed)), str(combo.get("atk_obs", "-"))])
	# ③ 真跑搜索
	var plan: Array = _ai.search(_sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var a2: Dictionary = st["action"]
		var mv: Variant = a2.get("move")
		var ti3 := int(a2.get("atk", -1))
		var tn3 := ("敲障碍%s" % str(a2.get("atk_obs"))) if a2.has("atk_obs") else "-"
		if ti3 >= 0 and ti3 < _sim.units.size():
			tn3 = String(_sim.units[ti3].name)
		txt += "%s[%s->%s,%s] " % [String(_sim.units[idx].name), str(_sim.units[idx].cell),
			("原地" if mv == null else str(mv)), tn3]
	print("PROBE|计划|%s" % txt)
	print("PROBE|搜索分账|阶段1 %d 套 → 送阶段2 %d 套" % [
		int(_ai.last_tp_layouts_built), int(_ai.last_tp_layouts_used)])
	var post = _sim.clone()
	for st2 in plan:
		_ai._apply(post, int(st2["idx"]), st2["action"])
	print("PROBE|计划终局|分=%.2f|玩家剩血：%s" % [float(_ai._evaluate(post, true)), _hp_txt(post)])
	# ④ 反事实：在"白游侠那一步之前"的局面 pre 上逐个候选算分
	var pre = _sim.clone()
	var bd0 := float(_ai._evaluate(pre, false))
	for st3 in plan:
		if int(st3["idx"]) == _bx:
			break
		_ai._apply(pre, int(st3["idx"]), st3["action"])
	var bd_pre: Dictionary = _ai._eval_breakdown(pre)
	print("PROBE|反事实基准|白游侠出手前的局面：该态分=%.2f|③血量账=%.2f" % [
		float(_ai._evaluate(pre, false)), float(bd_pre.get("③血量账", 0.0))])
	var best_gain := -1e9
	var best_txt := ""
	for combo2 in _ai._actions_for(pre, _bx):
		var s2 = pre.clone()
		_ai._apply(s2, _bx, combo2)
		var sc := float(_ai._evaluate(s2, false))
		var bd2: Dictionary = _ai._eval_breakdown(s2)
		var mv2: Variant = combo2.get("move")
		var ti4 := int(combo2.get("atk", -1))
		var tn4 := ("敲障碍%s" % str(combo2.get("atk_obs"))) if combo2.has("atk_obs") else "不出手"
		if ti4 >= 0 and ti4 < pre.units.size():
			tn4 = "打" + String(pre.units[ti4].name)
		var dsc := sc - bd0
		if dsc > best_gain:
			best_gain = dsc
			best_txt = "move=%s %s" % [("原地" if mv2 == null else str(mv2)), tn4]
		print("PROBE|反事实|move=%s %s|该态分=%.2f（Δ%+.2f）|③=%+.2f ④=%+.2f ⑦=%+.2f|玩家剩血 %s" % [
			("原地" if mv2 == null else str(mv2)), tn4, sc, dsc,
			float(bd2.get("③血量账", 0.0)) - float(bd_pre.get("③血量账", 0.0)),
			float(bd2.get("④集火frac²", 0.0)) - float(bd_pre.get("④集火frac²", 0.0)),
			float(bd2.get("⑦核心风险", 0.0)) - float(bd_pre.get("⑦核心风险", 0.0)), _hp_txt(s2)])
	print("PROBE|反事实最好的一手|= %s（Δ%+.2f）" % [best_txt, best_gain])
	# ④b 手工把"退到 (1,1) 再打圣光"喂进去算分（模拟里生成层不产这条线 ⇒ 这里绕过生成层直接 `_apply`）
	for mv3 in [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]:
		for ti7 in _sim.units.size():
			var tg3 = _sim.units[ti7]
			if tg3.fn == DataRegistry.Faction.ENEMY or not tg3.alive:
				continue
			var act := { "move": mv3, "atk": ti7 }
			var s3 = pre.clone()
			_ai._apply(s3, _bx, act)
			var sc3 := float(_ai._evaluate(s3, false))
			var bd3: Dictionary = _ai._eval_breakdown(s3)
			print("PROBE|手工喂线|move=%s 打%s|该态分=%.2f（Δ%+.2f）|③=%+.2f ④=%+.2f ⑦=%+.2f|该态圣光盾=%s|玩家剩血 %s" % [
				str(mv3), String(tg3.name), sc3, sc3 - bd0,
				float(bd3.get("③血量账", 0.0)) - float(bd_pre.get("③血量账", 0.0)),
				float(bd3.get("④集火frac²", 0.0)) - float(bd_pre.get("④集火frac²", 0.0)),
				float(bd3.get("⑦核心风险", 0.0)) - float(bd_pre.get("⑦核心风险", 0.0)),
				str(bool((s3.units[ti7] as Object).get("shield"))), _hp_txt(s3)])
	# ⑤ 消融：放宽漏斗 / 退回单阶段
	var ablations := [
		{ "n": "INNER=64", "w": { "TWO_PHASE_INNER": 64 } },
		{ "n": "INNER=64+LAYOUTS=32", "w": { "TWO_PHASE_INNER": 64, "TWO_PHASE_LAYOUTS": 32 } },
		{ "n": "DEDUP=0", "w": { "TWO_PHASE_DEDUP": 0 } },
		{ "n": "SEARCH_MODE=0（单阶段）", "w": { "SEARCH_MODE": 0 } },
	]
	for ab in ablations:
		_ai.set_weights(_nm)
		_ai.set_weights(ab["w"])
		var pl: Array = _ai.search(_sim.clone(), DataRegistry.Faction.ENEMY)
		var t2 := ""
		for st4 in pl:
			var idx4 := int(st4["idx"])
			var a4: Dictionary = st4["action"]
			var mv4: Variant = a4.get("move")
			var n4 := ("敲障碍%s" % str(a4.get("atk_obs"))) if a4.has("atk_obs") else "-"
			var ti5 := int(a4.get("atk", -1))
			if ti5 >= 0 and ti5 < _sim.units.size():
				n4 = String(_sim.units[ti5].name)
			t2 += "%s[%s->%s,%s] " % [String(_sim.units[idx4].name), str(_sim.units[idx4].cell),
				("原地" if mv4 == null else str(mv4)), n4]
		var p2 = _sim.clone()
		for st5 in pl:
			_ai._apply(p2, int(st5["idx"]), st5["action"])
		print("PROBE|消融 %s|%s|终局分=%.2f" % [String(ab["n"]), t2, float(_ai._evaluate(p2, true))])
	_ai.set_weights(_nm)
	print("PROBE|END")
	get_tree().quit(0)

func _hp_txt(s) -> String:
	var out := ""
	for i in s.units.size():
		var u = s.units[i]
		if u.fn != DataRegistry.Faction.ENEMY:
			out += "%s=%d " % [String(u.name), int(u.hp)]
	return out

# ---------------------------------------------------------------- 工具（与 锤头鲨不前进自检 同款）
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = CAP_MS
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, over: Dictionary = {}) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	for k in over.keys():
		d[k] = over[k]
	return d

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary:
		return d
	return {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
