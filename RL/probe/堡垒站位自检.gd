extends Node
## 【2026-09-28 一次性探针】装甲堡垒（hero_48）"站在一边当孤儿"自检 —— 用户实报：
##   「现在装甲堡垒还是不太聪明，有时候他能被玩家打到，但站的位置一点都不影响玩家打其他人，就像个孤儿站在一边」。
##
## 要回答的是：**它有没有动机往"能挡住枪线"的位置挪**。做法 = 同一批敌人、同一个我方，
##   只把堡垒放在**两个位置**上，各量一次：
##     ① `_evaluate()` 总分（末态口径）—— 引擎眼里这两个位置差多少分；
##     ② 堡垒自己那一项（⑭ 坚固 / ㉑ 退路 / ㉓ 离队）—— 钱到底付在哪；
##     ③ **嘲讽吸火的面**：关掉嘲讽门时我方非嘲讽单位的挨打合计 vs 实际 ⇒ 这个位置上它到底挡下了多少
##        （= ㉕ 的输入；它自己站一边时应当 ≈ 0）；
##     ④ 真跑一遍 `search()`，看它**实际会不会挪**（以及挪到哪）。
##
## 位置选择（让"站位有没有用"这件事可判）：
##   · **孤位 (0,4)**：缩在左下角、离我方另外两人远 ⇒ 谁也没挡住（用户描述的那种）
##   · **挡位 (3,2)**：站到我方两人**朝敌人那一侧**、把两个敌人的开火线切断
## 棋盘：7×5；我方 = 堡垒 + 白游侠(hero_10) + 火枪手(hero_09)（都摆在中场）；敌方 = 影丸 + 巨剑 + 风语者。
## 输出：每行 `TANK|...`，末尾 `TANK|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"
const MELEE := 0

var _grid: HexGrid
var _w: Dictionary = {}
## 【剂量用】非空时 _mk_ai() 用它替换 _w（注入 TANK_SCREEN_W 做对照）。
var _dose: Dictionary = {}
var _logf: FileAccess = null

func _log(s: String) -> void:
	print(s)
	if _logf == null:
		_logf = FileAccess.open("res://.godot_userdata/_tank_probe.log", FileAccess.WRITE)
	if _logf != null:
		_logf.store_line(s)
		_logf.flush()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	_w = _load_flat_weights(NIGHTMARE_PATH)
	_log("TANK|CFG|fork=%s|SOLID_HOLD_W=%.2f|TAUNT_SOAK_W=%.2f|FORM_COHESION_W=%.2f|FORM_ESCAPE_W=%.2f|FORM_SPREAD_CELL_W=%.2f" % [
		_sha("res://RL/ai/AI_Battle.gd"),
		float(_w.get("SOLID_HOLD_W", 0.0)), float(_w.get("TAUNT_SOAK_W", 0.0)),
		float(_w.get("FORM_COHESION_W", 0.0)), float(_w.get("FORM_ESCAPE_W", 0.0)),
		float(_w.get("FORM_SPREAD_CELL_W", 0.0))])
	# 堡垒自己的键写在 hero_48 段里，扁平兜底 0 —— 单独读出来确认
	var lone = _mk_ai(_w)
	_log("TANK|读数|`_wh(\"hero_48\", \"SOLID_HOLD_W\", %.2f)` = **%.2f** ｜ `_wh(\"hero_48\", \"TAUNT_SOAK_W\", %.2f)` = %.2f" % [
		float(_w.get("SOLID_HOLD_W", 0.0)), float(lone._wh("hero_48", "SOLID_HOLD_W", float(_w.get("SOLID_HOLD_W", 0.0)))),
		float(_w.get("TAUNT_SOAK_W", 0.0)), float(lone._wh("hero_48", "TAUNT_SOAK_W", float(_w.get("TAUNT_SOAK_W", 0.0))))])
	_arm("孤位 (0,4)·谁也没挡住", Vector2i(0, 4))
	_arm("挡位 (3,2)·切断开火线", Vector2i(3, 2))
	_scan()
	_walk()
	_dose_cmp()
	_log("TANK|END")
	get_tree().quit(0)

## 【本项改动（㉘堡垒挡刀）的靶子】同一局、同一个起点，只切 `TANK_SCREEN_W`：
##   看 ① 堡垒的候选分有没有"往挡位走"的梯度 ② `search()` 最终把它放哪（挡下多少血点）。
func _dose_cmp() -> void:
	for dose in [
		{ "tag": "㉘ 关（旧行为）", "w": 0.0 },
		{ "tag": "㉘ = 0.75", "w": 0.75 },
		{ "tag": "㉘ = 1.5", "w": 1.5 },
		{ "tag": "㉘ = 3.0", "w": 3.0 },
		{ "tag": "㉘ = 6.0", "w": 6.0 },
		{ "tag": "㉘ = 12.0", "w": 12.0 },
	]:
		var w2: Dictionary = _w.duplicate()
		w2["TANK_SCREEN_W"] = float(dose["w"])
		_dose = w2
		_log("TANK|剂量[%s]|起点 = 堡垒(1,2)（挡下 0）" % str(dose["tag"]))
		_walk()
		_log("TANK|剂量[%s]|起点 = 堡垒(2,3)（挡下 8.00 —— 它会不会守住这一格）" % str(dose["tag"]))
		_walk_from(Vector2i(2, 3))
		_dose = {}

## 关键分水岭：把堡垒**从某个位置**开局，看 `search()` 会不会把它挪到/留在**真能挡住**的格
##   （(2,3)/(3,4) 这些挡下 8~9 血点的位置）。⇒ 会挪 = 评分够用；不挪 = 缺一项"站位价值"的钱。
func _walk() -> void:
	_walk_from(Vector2i(1, 2))

func _walk_from(start: Vector2i) -> void:
	var E := DataRegistry.Faction.ENEMY
	var descs := _descs(start)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = _mk_ai(_w)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	# 堡垒这一手的全部候选，按末态分排序（看"走哪一格"分别值多少）
	var base := float(ai._evaluate(sim, true))
	var rows: Array = []
	for a in ai._actions_for(sim, 0):
		var s2 = sim.clone()
		ai._apply(s2, 0, a)
		var mv: Variant = a.get("move")
		rows.append({
			"d": float(ai._evaluate(s2, true)) - base,
			"txt": ("原地" if mv == null else "走到 " + str(mv)) + ("，不出手" if int(a.get("atk", -1)) < 0 else "，打 " + str(sim.units[int(a["atk"])].name)),
		})
	rows.sort_custom(func(x, y): return float(x["d"]) > float(y["d"]))
	_log("TANK|挪窝测试|堡垒候选 %d 条（末态分降序，前 8）：" % rows.size())
	for i in mini(8, rows.size()):
		_log("TANK|挪窝测试|  %+.3f  %s" % [float(rows[i]["d"]), str(rows[i]["txt"])])
	_log("TANK|挪窝测试|起点 %s 的 ㉘ 读数：w=%.2f ｜ `_tank_screen_val`=%.3f ｜ 入账=%+.3f" % [
		str(start), float(ai._wh("hero_48", "TANK_SCREEN_W", ai.w_tank_screen)),
		float(ai._tank_screen_val(sim)),
		float(ai._wh("hero_48", "TANK_SCREEN_W", ai.w_tank_screen)) * float(ai._tank_screen_val(sim))])
	var path: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var plan: Array[String] = []
	for st in path:
		var idx := int((st as Dictionary)["idx"])
		var a2: Dictionary = (st as Dictionary)["action"]
		var nm := str(sim.units[idx].name)
		if a2.get("move") != null:
			plan.append("%s 走到 %s%s" % [nm, str(a2["move"]),
				("" if int(a2.get("atk", -1)) < 0 else "，打 %s" % str(sim.units[int(a2["atk"])].name))])
		elif int(a2.get("atk", -1)) >= 0:
			plan.append("%s 原地打 %s" % [nm, str(sim.units[int(a2["atk"])].name)])
		else:
			plan.append("%s 不动" % nm)
	_log("TANK|挪窝测试|search() 计划：%s" % " → ".join(plan))

## 位置扫描：同一套敌我，把堡垒逐个放到候选格上，量"这一格挡住多少 + 引擎给多少分"。
## 目的：回答"它到底有没有**任何**一格是真在挡刀"（若全为 0 ⇒ 这机制在这套盘面上本来就没使上劲）。
func _scan() -> void:
	_log("TANK|扫描：堡垒放到各候选格 ⇒ 挡下血点 / 末态总分 / ⑭坚固 / 它自己挨打合计")
	for c in [Vector2i(0, 4), Vector2i(1, 3), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2),
			Vector2i(2, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(2, 4)]:
		var r: Dictionary = _measure(c)
		_log("TANK|扫描|堡垒@%-8s ⇒ 挡下 **%5.2f** 血点 ｜ 总分 %8.2f ｜ ⑭=%+.2f ｜ 自己挨打合计 %.2f" % [
			str(c), float(r["blocked"]), float(r["total"]), float(r["solid"]), float(r["own_inc"])])

func _measure(tank_cell: Vector2i) -> Dictionary:
	var E := DataRegistry.Faction.ENEMY
	var descs := _descs(tank_cell)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = _mk_ai(_w)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var free_sum := 0.0
	var real_sum := 0.0
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != E or u.skills.has(DataRegistry.Skill.TAUNT):
			continue
		free_sum += float(ai._inc_memoized(sim, u, u.cell, true))
		real_sum += float(ai._inc_memoized(sim, u, u.cell))
	var bd: Dictionary = ai._eval_breakdown(sim, true)
	var solid := 0.0
	for k in bd.keys():
		if str(k).begins_with("⑭"):
			solid = float(bd[k])
	return {
		"total": float(ai._evaluate(sim, true)),
		"solid": solid,
		"blocked": free_sum - real_sum,
		"own_inc": float(ai._inc_memoized(sim, sim.units[0], sim.units[0].cell)),
	}

func _descs(tank_cell: Vector2i) -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	return [
		_u(E, "hero_48", tank_cell, 36, 36, 1, 2, 1, MELEE, [DataRegistry.Skill.TAUNT], "装甲堡垒(我方)"),
		_u(E, "hero_10", Vector2i(2, 3), 19, 19, 2, 2, 2, 1, [], "白游侠(我方)"),
		_u(E, "hero_09", Vector2i(3, 4), 20, 20, 4, 2, 2, 1, [], "火枪手(我方)"),
		_u(P, "hero_07", Vector2i(4, 1), 14, 14, 5, 2, 1, MELEE, [], "影丸"),
		_u(P, "hero_12", Vector2i(5, 2), 24, 24, 2, 2, 1, MELEE, [], "巨剑"),
		_u(P, "hero_43", Vector2i(6, 4), 14, 14, 1, 2, 2, 1, [], "风语者"),
	]

## 一套盘面 = 敌我相同、只挪堡垒；逐项量"这个位置值多少"。
func _arm(tag: String, tank_cell: Vector2i) -> void:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var descs := [
		_u(E, "hero_48", tank_cell, 36, 36, 1, 2, 1, MELEE, [DataRegistry.Skill.TAUNT], "装甲堡垒(我方)"),
		_u(E, "hero_10", Vector2i(2, 3), 19, 19, 2, 2, 2, 1, [], "白游侠(我方)"),
		_u(E, "hero_09", Vector2i(3, 4), 20, 20, 4, 2, 2, 1, [], "火枪手(我方)"),
		_u(P, "hero_07", Vector2i(4, 1), 14, 14, 5, 2, 1, MELEE, [], "影丸"),
		_u(P, "hero_12", Vector2i(5, 2), 24, 24, 2, 2, 1, MELEE, [], "巨剑"),
		_u(P, "hero_43", Vector2i(6, 4), 14, 14, 1, 2, 2, 1, [], "风语者"),
	]
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = _mk_ai(_w)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	# 【诊断】㉘ 的原始读数（引擎里那一项到底算出几）
	var tank_u = sim.units[0]
	var wts := float(ai._wh("hero_48", "TANK_SCREEN_W", ai.w_tank_screen))
	var sv := float(ai._tank_screen_val(sim))
	_log("TANK|%s|㉘读数：w=%.2f ｜ `_tank_screen_val`=%.3f ｜ 该项入账=%+.3f ｜ 堡垒 pool=%.2f" % [
		tag, wts, sv, wts * sv, float(ai._incoming_pool_mult(tank_u))])
	var total := float(ai._evaluate(sim, true))
	_log("TANK|%s|堡垒@%s ⇒ **末态总分 %.2f**" % [tag, str(tank_cell), total])
	# 逐项（看 ⑭/㉑/㉓ 各付了多少）
	var bd: Dictionary = ai._eval_breakdown(sim, true)
	var keys: Array = bd.keys()
	keys.sort_custom(func(a, b): return absf(float(bd[a])) > absf(float(bd[b])))
	var bits: Array[String] = []
	for k in keys:
		if absf(float(bd[k])) < 0.005:
			continue
		bits.append("%s=%+.2f" % [str(k), float(bd[k])])
	_log("TANK|%s|逐项：%s" % [tag, " ｜ ".join(bits)])
	# 嘲讽吸火：关掉门 vs 实际（= ㉕ 的输入）
	var free_sum := 0.0
	var real_sum := 0.0
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != E or u.skills.has(DataRegistry.Skill.TAUNT):
			continue
		var free_inc := float(ai._inc_memoized(sim, u, u.cell, true))
		var real_inc := float(ai._inc_memoized(sim, u, u.cell))
		free_sum += free_inc
		real_sum += real_inc
		_log("TANK|%s|  %s：关掉嘲讽门挨打=%.2f → 实际=%.2f（挡下 %.2f）" % [
			tag, str(u.name), free_inc, real_inc, free_inc - real_inc])
	_log("TANK|%s|嘲讽吸火合计：关掉门 %.2f → 实际 %.2f ⇒ **挡下 %.2f 血点**（㉕ = ×%.2f = %.2f 分）" % [
		tag, free_sum, real_sum, free_sum - real_sum, float(ai._wh("hero_48", "TAUNT_SOAK_W", float(_w.get("TAUNT_SOAK_W", 0.0)))),
		(free_sum - real_sum) * float(ai._wh("hero_48", "TAUNT_SOAK_W", float(_w.get("TAUNT_SOAK_W", 0.0))))])
	# 堡垒自己会不会挪：真跑 search()
	var path: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var plan: Array[String] = []
	for st in path:
		var idx := int((st as Dictionary)["idx"])
		var a: Dictionary = (st as Dictionary)["action"]
		var nm := str(sim.units[idx].name)
		if a.get("move") != null:
			plan.append("%s 走到 %s%s" % [nm, str(a["move"]),
				("" if int(a.get("atk", -1)) < 0 else "，打 %s" % str(sim.units[int(a["atk"])].name))])
		elif int(a.get("atk", -1)) >= 0:
			plan.append("%s 原地打 %s" % [nm, str(sim.units[int(a["atk"])].name)])
		else:
			plan.append("%s 不动" % nm)
	_log("TANK|%s|search() 计划：%s" % [tag, " → ".join(plan)])

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 1500
	ai.set_weights(_dose if not _dose.is_empty() else inject)
	return ai

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

func _load_flat_weights(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = {}
	for k in (d as Dictionary).keys():
		if str(k).begins_with("_"):
			continue
		out[str(k)] = (d as Dictionary)[k]
	return out

func _sha(path: String) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
