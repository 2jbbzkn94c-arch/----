extends Node
## 【2026-10-02 一次性探针·只读】复刻用户实机那一盘，回答：
##   「伐木工为什么没有去贴影丸（贴住就能把影丸的攻击 5 压到 1）」。
## 复刻源（用户贴的转储，界面口径 ⇒ 本文件一律 0 基 = 界面 −1）：
##   我方(AI/ENEMY)：hero_48 装甲堡垒 (2,6) hp24/36 · hero_01 伐木工 (1,4) hp10/27 · hero_14 古拉博士 (2,5) hp4/15
##   玩家(PLAYER)  ：hero_07 影丸 (0,6) hp10/14 atk5 r2 · hero_22 圣光 (1,5) hp13/21【嘲讽＋圣盾】· hero_29 太阳斩 (1,6) hp8/16
##   障碍 (0,4) (0,3) (4,4)
## 打印：① `search()` 的选择（应当复刻实机：三人都"原地打圣光"）② 阶段 1 到底产出了几套阵型
##   ③ 伐木工的**全部移动候选**（贴影丸那一格在不在里面）④ 把伐木工换成"贴影丸"那一手之后的完整 `_evaluate` 与分账。
const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"     # 实机那一档（esc 门 = 1）

var _grid: HexGrid
var _nm: Dictionary = {}
var _role_on := false      # 命令行带 `role` ⇒ 额外注入 FORM_ROLE_GATE=1
var _ranged_on := false    # 命令行带 `ranged` ⇒ 额外注入 FORM_ESCAPE_RANGED_ONLY=1

func _ready() -> void:
	for ua in OS.get_cmdline_user_args():
		if String(ua) == "role":
			_role_on = true
		if String(ua) == "ranged":
			_ranged_on = true
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|180s 到点，强制退出")
		get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_48", Vector2i(2, 6), "装甲堡垒", { "hp": 24 }),
		_desc(DataRegistry.Faction.ENEMY, "hero_01", Vector2i(1, 4), "伐木工",   { "hp": 10 }),
		_desc(DataRegistry.Faction.ENEMY, "hero_14", Vector2i(2, 5), "古拉博士", { "hp": 4 }),
		_desc(DataRegistry.Faction.PLAYER, "hero_07", Vector2i(0, 6), "影丸",   { "hp": 10 }),
		_desc(DataRegistry.Faction.PLAYER, "hero_22", Vector2i(1, 5), "圣光",   { "hp": 13, "shield": true }),
		_desc(DataRegistry.Faction.PLAYER, "hero_29", Vector2i(1, 6), "太阳斩", { "hp": 8 }),
	]
	var obs := { Vector2i(0, 4): true, Vector2i(0, 3): true, Vector2i(4, 4): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]

	print("PROBE|CFG|esc=%s|EXPOSURE_TOTAL_W=%s|EXPOSURE_HP_MAX=%s|FORM_ESCAPE_W=%s|FORM_SPREAD_CELL_W=%s|FORM_COHESION_W=%s|AOE_RIDER_TOTAL_W=%s" % [
		str(_nm.get("FORM_ESCAPE_ESCAPABLE", "-")), str(_nm.get("EXPOSURE_TOTAL_W", "-")),
		str(_nm.get("EXPOSURE_HP_MAX", "-")), str(_nm.get("FORM_ESCAPE_W", "-")),
		str(_nm.get("FORM_SPREAD_CELL_W", "-")), str(_nm.get("FORM_COHESION_W", "-")),
		str(_nm.get("AOE_RIDER_TOTAL_W", "-"))])

	# ① 真搜索：应当复刻实机（三人原地打圣光）
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("PROBE|① search() 选了 %d 步" % plan.size())
	for st in plan:
		var i := int(st["idx"])
		var a: Dictionary = st["action"]
		var u = sim.units[i]
		print("PROBE|    %s(%s) move=%s atk=%s" % [u.name, u.hero_id, str(a.get("move")), str(a.get("atk"))])
	print("PROBE|② 阶段1 阵型=%d 套 · 送阶段2=%d 套 · 阶段1评分=%d（丢重=%d）· 阶段2评分=%d · 完整计划=%d" % [
		ai.last_tp_layouts_built, ai.last_tp_layouts_used, ai.last_tp_p1_evals, ai.last_tp_p1_dups,
		ai.last_tp_p2_evals, ai.last_tp_leaves])

	# ③ 伐木工的全部移动候选（找"贴影丸"那一格在不在）
	var li := 1
	print("PROBE|③ 伐木工 在 (%s) 的移动候选：" % str(sim.units[li].cell))
	var moves: Array = ai._tp_move_actions(sim, li)
	for a in moves:
		var mv = a.get("move")
		print("PROBE|    move=%s" % (str(mv) if mv != null else "（原地）"))

	# ④ 整回合同口径对拍：三手都定死，只用 `_evaluate(s, true)` 比（与阶段 2 收尾同一把尺）
	print("PROBE|④ 整回合对拍（三手都显式指定；尺子 = _evaluate(s, true)）")
	var planA: Array = [   # 实机那一手：三人原地打圣光（idx4）
		{ "i": 0, "a": { "move": null, "atk": 4 } },
		{ "i": 2, "a": { "move": null, "atk": 4 } },
		{ "i": 1, "a": { "move": null, "atk": 4 } },
	]
	var planB: Array = [   # 用户问的那一手：伐木工走到 (0,5) 贴住影丸，仍然打圣光
		{ "i": 0, "a": { "move": null, "atk": 4 } },
		{ "i": 2, "a": { "move": null, "atk": 4 } },
		{ "i": 1, "a": { "move": Vector2i(0, 5), "atk": 4 } },
	]
	var planC: Array = [   # 对照：只贴、不打
		{ "i": 0, "a": { "move": null, "atk": 4 } },
		{ "i": 2, "a": { "move": null, "atk": 4 } },
		{ "i": 1, "a": { "move": Vector2i(0, 5), "atk": -1 } },
	]
	var rA := _apply_plan(ai, sim, planA, "A 实机：三人原地打圣光")
	var rB := _apply_plan(ai, sim, planB, "B 用户问的：伐木工贴影丸(0,5) + 仍打圣光")
	var rC := _apply_plan(ai, sim, planC, "C 只贴影丸、不打")
	print("PROBE|    B − A = %+.2f ｜ C − A = %+.2f" % [
		float(rB["ev"]) - float(rA["ev"]), float(rC["ev"]) - float(rA["ev"])])
	print("PROBE|    【B−A 分账】%s" % ai._breakdown_line(rA["bd"], rB["bd"], float(rB["ev"]) - float(rA["ev"])))
	print("PROBE|    【C−A 分账】%s" % ai._breakdown_line(rA["bd"], rC["bd"], float(rC["ev"]) - float(rA["ev"])))
	# 搜索自己选的那一手，用同一把尺量一遍
	var s2 = sim.clone()
	for st in plan:
		ai._apply(s2, int(st["idx"]), st["action"])
	print("PROBE|    搜索自己那套（逐手回放后 _evaluate）= %+.2f" % ai._evaluate(s2, true))

	# ⑤ 伐木工在 (0,5) 能打谁（嘲讽门有没有把圣光挡掉）
	var s5 = sim.clone()
	ai._apply(s5, 1, { "move": Vector2i(0, 5), "atk": -1 })
	print("PROBE|⑤ 伐木工在 (0,5)：与圣光相邻=%s · 与影丸相邻=%s · 可打目标=%s" % [
		str(ai._sim_enemy_adjacent(s5, s5.units[1], Vector2i(0, 5))),
		str(ai._sim_enemy_adjacent(s5, s5.units[3], Vector2i(0, 5))),
		str(ai._valid_targets(s5, s5.units[1], Vector2i(0, 5)))])

	# ⑥ 逐单位曝光账（把 ㉖ 那 −4.00 落到具体是谁）
	var sA2 = sim.clone()
	for st in planA:
		ai._apply(sA2, int(st["i"]), st["a"])
	var sB2 = sim.clone()
	for st in planB:
		ai._apply(sB2, int(st["i"]), st["a"])
	print("PROBE|⑥ 逐单位曝光账：名字 · 血上限 · 输出潜力 · 进㉖门?) · A 挨打 · B 挨打")
	for i in [0, 1, 2]:
		var ua = sA2.units[i]
		var ub = sB2.units[i]
		print("PROBE|    %s hp上限=%d 输出潜力=%.1f 进门=%s ⇒ A 挨打=%.1f · B 挨打=%.1f（影丸 eatk：A=%d B=%d）" % [
			ua.name, ua.max_hp, ai._output_potential(ua.hero_id), str(ai._exposure_covered(ua)),
			ai._incoming_total_on(sA2, ua, ua.cell), ai._incoming_total_on(sB2, ub, ub.cell),
			int(sA2.units[3].eatk), int(sB2.units[3].eatk)])

	# ⑦ 邻接关系本体（(0,5) 到底挨不挨着影丸 (0,6)？）—— 这决定了"那一格算不算贴身"
	print("PROBE|⑦ (0,5) 的邻居 = %s" % str(_grid.neighbors(Vector2i(0, 5))))
	print("PROBE|    格距 (0,5)-(0,6) = %d · (0,5)-(1,5) = %d · (1,4)-(0,5) = %d" % [
		_grid.distance(Vector2i(0, 5), Vector2i(0, 6)), _grid.distance(Vector2i(0, 5), Vector2i(1, 5)),
		_grid.distance(Vector2i(1, 4), Vector2i(0, 5))])
	print("PROBE|    _sim_enemy_adjacent(s5, 伐木工@(0,5), (0,5)) = %s（问：那一格四周有没有敌对的）" % str(ai._sim_enemy_adjacent(s5, s5.units[1], Vector2i(0, 5))))
	var sB3 = sim.clone()
	ai._apply(sB3, 1, { "move": Vector2i(0, 5), "atk": -1 })
	print("PROBE|    B 之后：影丸@%s 的 eatk=%d（若被贴身应为 1）· 伐木工@%s" % [
		str(sB3.units[3].cell), int(sB3.units[3].eatk), str(sB3.units[1].cell)])
	print("PROBE|END")
	get_tree().quit(0)

func _apply_plan(ai, sim, plan: Array, label: String) -> Dictionary:
	var s = sim.clone()
	for st in plan:
		ai._apply(s, int(st["i"]), st["a"])
	var ev: float = ai._evaluate(s, true)
	var bd: Dictionary = ai._eval_breakdown(s, true)
	print("PROBE|    %s ⇒ _evaluate=%+.2f" % [label, ev])
	return { "ev": ev, "bd": bd }

## 其余两人固定为"原地打圣光(idx=4)"，只换伐木工那一手
func _plan_score_fixed(ai, sim, li: int, act: Dictionary) -> float:
	var s = sim.clone()
	ai._apply(s, li, act)
	for i in [0, 2]:
		var acts: Array = ai._actions_for(s, i)
		var best: Dictionary = {}
		var best_v := -INF
		for a2 in acts:
			var s2 = s.clone()
			ai._apply(s2, i, a2)
			var v: float = ai._evaluate(s2, false)
			if v > best_v:
				best_v = v
				best = a2
		if not best.is_empty():
			ai._apply(s, i, best)
	return ai._evaluate(s, true)

## 从 move 那一格出发，挑一个"打谁"（用完整评分挑，和阶段 2 同一把尺）
func _best_from(ai, sim, li: int, mv: Vector2i) -> Dictionary:
	var s = sim.clone()
	ai._apply(s, li, { "move": mv, "atk": -1 })
	var out: Dictionary = {}
	var best_v := -INF
	for a in ai._tp_attack_actions(s, li):
		var s2 = s.clone()
		ai._apply(s2, li, a)
		var v: float = ai._evaluate(s2, false)
		if v > best_v:
			best_v = v
			out = { "move": mv, "atk": a.get("atk") }
			for k in a.keys():
				out[k] = a[k]
	return out

func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)
	if _role_on:
		ai.set_weights({ "FORM_ROLE_GATE": 1 })   # 只加这一道门，其余与实机同
	if _ranged_on:
		ai.set_weights({ "FORM_ESCAPE_RANGED_ONLY": 1 })
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
	return d if d is Dictionary else {}
