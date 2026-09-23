extends Node
## 【2026-09-23 一次性探针】发呆日志自检 —— 跑完即退，**不改任何生产代码**。
##
## 目的：验证 `_print_decision()` 新加的那段「**整回合没动作**的单位也要写出来，并说清为什么」
##   （用户原话：「原地不动的也要写出来什么原因」）。
## 盘面用**用户实机那张**「装甲堡垒蹲角落」的局（`PICTURE/堡垒不向前.png` 那一轮）——
##   它是"计划里确实没有它的步骤"的典型：⑭坚固驻守让它宁可站着不动。
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag idlelog -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/发呆日志自检.tscn')
## 输出：`search()` 打出来的**整套决策日志**（含新加的"整回合没动作"段）。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_48", Vector2i(0, 1), "装甲堡垒"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_04", Vector2i(2, 2), "鼠队长"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_03", Vector2i(3, 2), "毒蛇淑女"))
	# 【验证用】再放一个「后勤」单位（涌电技师）⇒ 它**永远没有攻击候选**，
	#   用来跑通日志里那条"没有任何能打到人的出招：它是后勤…"的分支（否则那段代码只编译过、没执行过）。
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_38", Vector2i(4, 1), "涌电技师"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_47", Vector2i(2, 3), "共鸣者"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_10", Vector2i(2, 4), "白游侠"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_49", Vector2i(3, 4), "荆棘树人"))
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = true          # ← 本探针的唯一目的：把决策日志打出来
	ai.time_budget_ms = 20000
	ai.set_weights(_load_json(WEIGHTS))
	var sim = ai.build_state(descs, occ, {}, {}, { Vector2i(1, 3): true }, {}, {})
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	for st in plan:
		txt += "%s[%s->%s,atk=%d] " % [String(sim.units[int(st["idx"])].name),
			str(sim.units[int(st["idx"])].cell), str(st["action"].get("move")), int(st["action"].get("atk", -1))]
	print("PROBE|PLAN|%s" % txt)
	# 【验证用】再手造一次"计划里**漏掉某个单位**"的情况（用户实机就是这种：搜索没轮到他 ⇒ 日志里
	#   他整个人消失）⇒ 直接把 `装甲堡垒`(idx=0) 从计划里删掉，再走一遍日志，看新加的那段会不会写出来。
	var cut: Array = []
	for st in plan:
		if int(st["idx"]) == 0:
			continue
		cut.append(st)
	var end2 = sim.clone()
	for st in cut:
		ai._apply(end2, int(st["idx"]), st["action"])
	print("PROBE|CUT|删掉装甲堡垒后的计划步数=%d" % cut.size())
	ai._print_decision(sim, { "path": cut, "score": ai._evaluate(end2, true), "sim": sim })
	print("PROBE|END")
	get_tree().quit(0)

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
	if d is Dictionary:
		return d
	return {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
