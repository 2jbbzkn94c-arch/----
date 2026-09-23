extends Node
## 【2026-09-23 一次性探针】远程贴身自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户的问题：「为什么白游侠要贴身打毒蛇？退后打一格打毒蛇可以打一共 4 伤啊」。
##   真实规则（`heroes/hero_10_白游侠.gd`）：**远程攻击时**散射（对目标相邻的敌人各再打一次
##   `effective_atk()` + 冰冻），且**远程被贴身时这一击不触发任何附带效果** ⇒
##      · 贴身打 = 基础攻击压 1、**不散射** ⇒ 一共 **1 伤**；
##      · 退到 2 格外打 = 2 伤 + 散射到「与毒蛇相邻的装甲堡垒」2 伤 ⇒ 一共 **4 伤**（用户口径）。
##   盘面按用户截图 `image.png`（第 3 回合）＋ 他贴的决策日志反推成**AI 回合开始那一刻**：
##     敌方(AI)：白游侠(1,3)【它这一刻贴着毒蛇 ⇒ `ranged_adjacent=true`、eatk=1】· 红帽(3,1) · 负墟(2,2)【嘲讽】
##     我方(玩家)：毒蛇淑女(2,3)24 · 装甲堡垒(2,4) · 涌电技师(3,4)【后勤，已走过两步 ⇒ eatk=2】
##     障碍：(1,4) 木桶（截图里那个耐久 1 的桶）
##   日志里 AI 选的计划是：负墟 (2,2)→(3,2) · 红帽 (3,1)→(2,2) · 然后三只一起打毒蛇（2+5+1）。
##
## 本探针查四件事：
##   ① 白游侠 这一刻的 `eatk / pin_flag / pin_buffs`（贴身是快照带来的缓存标记）；
##   ② 它这一回合**能站的每一格**：是否与敌人相邻、从那儿 `_valid_targets()` 能打谁、
##      以及**从那儿打毒蛇合不合法**（`_cell_in_range`＋几何距离）——即"退后一格"到底有没有路；
##   ③ `_actions_for()` 给出的**全部候选**（移动+攻击组合），以及两道远程闸门
##      （`safe_targets` 不贴脸闸门 / `_ranged_pinned_shot_ok` 的 `alt_best` 判据）各自放行了什么；
##   ④ 真跑一遍 `search()`（模式 2、beam 400）看它到底选了什么 —— 与用户日志对照。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag rpin -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/远程贴身自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const CAP_MS := 30000

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|SEARCH_MODE=%s|BEAM=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), str(_nm.get("BEAM", 0))])
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_10", Vector2i(1, 3), "白游侠",
		{ "ranged_adjacent": true, "eatk": 1 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(3, 1), "红帽", { "hp": 10 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_44", Vector2i(2, 2), "负墟", { "hp": 25 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_03", Vector2i(2, 3), "毒蛇淑女", { "hp": 24 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_48", Vector2i(2, 4), "装甲堡垒", {}))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_38", Vector2i(3, 4), "涌电技师",
		{ "hp": 24, "eatk": 2 }))
	var obs := { Vector2i(1, 4): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var u = sim.units[0]                      # 白游侠
	var snake = sim.units[3]                  # 毒蛇淑女
	print("PROBE|开局|白游侠@%s|atk=%d eatk=%d|pin_flag=%s pin_buffs=%d|射程=%d 类型=%d|emove=%d|与敌相邻=%s" % [
		str(u.cell), int(u.atk), int(u.eatk), str(u.pin_flag), int(u.pin_buffs),
		int(u.atk_range), int(u.atk_type), int(u.emove), str(ai._sim_enemy_adjacent(sim, u, u.cell))])
	# ② 逐格：能站哪、从那儿能打谁、从那儿能不能打毒蛇
	var reach: Array = ai._move_cells(sim, u).keys()
	reach.sort_custom(func(a, b): return _grid.distance(a as Vector2i, snake.cell) < _grid.distance(b as Vector2i, snake.cell))
	for c in reach:
		var cc: Vector2i = c
		var tns: Array = []
		for ti in ai._valid_targets(sim, u, cc):
			tns.append(String(sim.units[int(ti)].name))
		print("PROBE|格|%s|几何距毒蛇=%d|_cell_in_range(毒蛇)=%s|与敌相邻=%s|能打=%s" % [
			str(cc), _grid.distance(cc, snake.cell), str(ai._cell_in_range(sim, u, cc, snake.cell)),
			str(ai._sim_enemy_adjacent(sim, u, cc)), str(tns)])
	# ③ `_actions_for()` 全部候选 + 两道闸门的中间量
	var combos: Array = ai._actions_for(sim, 0)
	# 【2026-09-23 深夜⑮】这里改用**引擎自己的新 helper**（原来探针内部照抄旧式 `u.eatk` ⇒ 读数会停在旧的 1，
	#   与修好的引擎不一致 ⇒ 会让"修没修好"看起来没变）。
	var alt_best := 0
	for combo in combos:
		if int(combo.get("atk", -1)) < 0:
			continue
		var mc0: Vector2i = u.cell if combo.get("move") == null else combo["move"]
		if not ai._sim_enemy_adjacent(sim, u, mc0):
			alt_best = maxi(alt_best, int(ai._sim_free_atk(u)))
	var pinned_atk := int(ai._sim_pinned_atk(u))
	print("PROBE|闸门|alt_best=%d pinned_atk=%d|候选数=%d" % [alt_best, pinned_atk, combos.size()])
	for combo in combos:
		var mc: Vector2i = u.cell if combo.get("move") == null else combo["move"]
		var ti := int(combo.get("atk", -1))
		var tn := "-"
		if ti >= 0 and ti < sim.units.size():
			tn = String(sim.units[ti].name)
		var dmg := "-"
		if ti >= 0:
			dmg = str(ai._threat_hit_value(sim, u, int(ai.walk_dist(sim, mc, sim.units[ti].cell)), false))
		print("PROBE|候选|move=%s atk=%d(%s)|开火时贴敌=%s|预计伤害=%s|过贴身闸门=%s" % [
			("原地" if combo.get("move") == null else str(mc)), ti, tn,
			str(ai._sim_enemy_adjacent(sim, u, mc)), dmg,
			str(ai._ranged_pinned_shot_ok(sim, u, combo, alt_best))])
	# ④ 真跑一遍搜索
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		var ti2 := int(act.get("atk", -1))
		var tn2 := "-"
		if ti2 >= 0 and ti2 < sim.units.size():
			tn2 = String(sim.units[ti2].name)
		txt += "%s[%s->%s,atk=%s] " % [String(sim.units[idx].name), str(sim.units[idx].cell),
			("原地" if mv == null else str(mv)), tn2]
	print("PROBE|计划|%s" % txt)
	# ⑤ 关键对照：**原地打** vs **退到 (1,1)/(0,3) 再打** —— 让模拟真结算，看掉血几滴、终局分多少
	print("PROBE|对照|口径：先移动（若需要）→ 再攻击毒蛇 ⇒ 看它真扣几滴血")
	for tm in [null, Vector2i(1, 1), Vector2i(0, 3), Vector2i(1, 5)]:
		var s2 = sim.clone()
		if tm != null:
			ai._apply(s2, 0, { "move": tm, "atk": -1 })
		var eu = s2.units[0]
		var pin_note := "开火前：cell=%s eatk=%d pin_flag=%s" % [str(eu.cell), int(eu.eatk), str(eu.pin_flag)]
		var hp_before := int(s2.units[3].hp)
		ai._apply(s2, 0, { "move": null, "atk": 3 })
		print("PROBE|对照|%s|%s|打毒蛇掉血=%d（剩 %d）|该状态终局分=%.2f" % [
			("原地" if tm == null else str(tm)), pin_note, hp_before - int(s2.units[3].hp),
			int(s2.units[3].hp), float(ai._evaluate(s2, true))])
	# ⑥ 把 ③④ 那个计划整段走完，看它到底从哪一格打、打掉几滴
	var pf = sim.clone()
	for st in plan:
		ai._apply(pf, int(st["idx"]), st["action"])
	print("PROBE|计划结算|毒蛇剩血=%d（开局 24 ⇒ 计划总共打掉 %d）|该终局分=%.2f" % [
		int(pf.units[3].hp), 24 - int(pf.units[3].hp), float(ai._evaluate(pf, true))])
	print("PROBE|END")
	get_tree().quit(0)

# ---------------------------------------------------------------- 工具
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
