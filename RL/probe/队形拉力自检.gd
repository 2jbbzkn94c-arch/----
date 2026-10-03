extends Node
## 【2026-10-03 一次性探针·只读】两件事的读数（都挂在 §五 T151 上）：
##   ① **(d)** `FORM_GUARD_GATE` 的"没人可护就整笔跳过"改成"**退回默认尺子 × `FORM_ROLE_TANK_MULT`(0.25)**"
##      ⇒ **全厚血阵容**里 ⑳抱团 / ㉓离队 重新有（弱）分（改前是**构造上的 0**：那句 `continue`）。
##      同时验证 ㉑ 在"没人可护"时**照旧跳过**（盘 A 里放了远程的厚血单位 —— 若 ㉑ 回来了它会非 0）。
##   ② **(a)** `ENGAGE_PULL_PER_CELL` 1.2 → 2.4 ⇒ ⑤位置拉力 **直接翻倍**（同一盘面跑两套权重）。
## 三个合成盘（5×7 · 只为读数；我方 = ENEMY 阵营 = AI 侧）：
##   盘 A **全"厚血/不须保护"**：复仇者 hero_23(26) @(1,1) · 白游侠 hero_10(19·远程) @(1,4) · 圣诞老人 hero_02(24) @(3,5)
##   盘 B **有脆皮输出**（须保护）：把圣诞老人换成 风语者 hero_43(14) @(3,5)
##   盘 C **有后勤**（须保护）：把圣诞老人换成 烛火 hero_17 @(3,5)
##   敌人（PLAYER）：小阴影 hero_15 @(4,6)，只为给 ⑤ 一个"最近的敌人"。
## 每盘打印 `_eval_breakdown()` 的 ⑳抱团 / ㉑退路 / ㉓离队 / ⑤位置拉力 四项（**引擎自己算的**，探针不重算）。
const AI_SRC := preload("res://src/BattleAI.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s"); get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var ai = AI_SRC.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)
	print("PROBE|权重：ENGAGE_PULL_PER_CELL=%.2f · FORM_COHESION_W=%.2f · FORM_SPREAD_CELL_W=%.2f · FORM_ROLE_GATE=%d(×%.2f) · FORM_GUARD_GATE=%d · FORM_ESCAPE_RANGED_ONLY=%d" % [
		ai.w_engage_pull, ai.w_form_cohesion, ai.w_form_spread,
		ai.w_form_role_gate, ai.w_form_role_tank_mult, ai.w_form_guard_gate, ai.w_form_escape_ranged_only])

	var boards: Array = [
		["A 全厚血（没有须保护队友）", "hero_02", "圣诞老人"],
		["B 有脆皮输出 风语者(14血)", "hero_43", "风语者"],
		["C 有后勤 烛火", "hero_17", "烛火"],
	]
	for bd in boards:
		var third: String = bd[1]
		var descs: Array = [
			_desc(DataRegistry.Faction.ENEMY, "hero_23", Vector2i(1, 1), "复仇者"),
			_desc(DataRegistry.Faction.ENEMY, "hero_10", Vector2i(1, 4), "白游侠"),
			_desc(DataRegistry.Faction.ENEMY, third, Vector2i(3, 5), String(bd[2])),
			_desc(DataRegistry.Faction.PLAYER, "hero_15", Vector2i(4, 6), "小阴影"),
		]
		var occ := {}
		for i in descs.size():
			occ[descs[i]["cell"]] = i
		var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
		print("PROBE|===== %s =====" % bd[0])
		for i in 3:
			var u = sim.units[i]
			print("PROBE|  %-6s @%s hp%d 须保护=%s 最近队友步数=%d" % [
				u.name, str(u.cell), u.hp, "是" if ai._form_is_protected(u) else "否", _nearest_mate(ai, sim, u)])
		var d: Dictionary = ai._eval_breakdown(sim, true)
		print("PROBE|  ⇒ ⑳抱团=%.2f · ㉑退路=%.2f · ㉓离队=%.2f · ⑤位置拉力=%.2f" % [
			float(d.get("⑳抱团", 0.0)), float(d.get("㉑退路/被夹", 0.0)),
			float(d.get("㉓离队距离", 0.0)), float(d.get("⑤位置拉力", 0.0))])

	# ③ (a) 的 A/B：同一盘面、只把 ENGAGE_PULL_PER_CELL 换成 1.2 再算一遍 ⑤
	var nm_low: Dictionary = _nm.duplicate(true)
	nm_low["ENGAGE_PULL_PER_CELL"] = 1.2
	var descsA: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_23", Vector2i(1, 1), "复仇者"),
		_desc(DataRegistry.Faction.ENEMY, "hero_10", Vector2i(1, 4), "白游侠"),
		_desc(DataRegistry.Faction.ENEMY, "hero_02", Vector2i(3, 5), "圣诞老人"),
		_desc(DataRegistry.Faction.PLAYER, "hero_15", Vector2i(4, 6), "小阴影"),
	]
	var occA := {}
	for i in descsA.size():
		occA[descsA[i]["cell"]] = i
	print("PROBE|===== (a) ⑤位置拉力 A/B（盘 A 原样） =====")
	for wv in [[1.2, nm_low], [2.4, _nm]]:
		ai.set_weights(wv[1])
		var sim2 = ai.build_state(descsA, occA, {}, {}, {}, {}, {})
		var d2: Dictionary = ai._eval_breakdown(sim2)
		var me = sim2.units[0]
		var near: int = ai._nearest_enemy_dist(sim2, me)
		print("PROBE|  ENGAGE_PULL_PER_CELL=%.1f ⇒ ⑤位置拉力=%.2f（复仇者到最近敌人 %d 步、门槛 %d）" % [
			ai.w_engage_pull, float(d2.get("⑤位置拉力", 0.0)), near, me.emove + me.atk_range])
	print("PROBE|END")
	get_tree().quit(0)

## 到最近队友的路网步数（复用引擎那把尺子）
func _nearest_mate(ai, sim, u) -> int:
	var best := 99
	for v in sim.units:
		if v == null or not v.alive or v == u or v.fn != u.fn:
			continue
		if DataRegistry.summons.has(v.hero_id):
			continue
		var d: int = ai.walk_dist(sim, u.cell, v.cell)
		if d < best:
			best = d
	return best


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

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}
