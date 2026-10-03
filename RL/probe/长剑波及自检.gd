extends Node
## 【2026-10-03 一次性探针·只读】把用户那一局的局面**原样摆出来**，逐条打印
## `_aoe_riders_on()` 给了哪些"AoE 波及"——用来回答「这一格到底会不会被长剑剑气打到」。
## 盘面（转储坐标 −1 换 0 基）：
##   我方 hero_10 白游侠@(0,1) · hero_27@(4,1) · hero_30 嬉皮死神@(2,1)
##   玩家 hero_18 长剑@(2,6) · hero_43@(1,6) · hero_40 红帽@(0,6)
##   障碍 (0,4)(0,3)(4,4)(4,3)
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
	var obst := {}
	for c in [Vector2i(0, 4), Vector2i(0, 3), Vector2i(4, 4), Vector2i(4, 3)]:
		obst[c] = true
	var ai = AI_SRC.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)

	# 每个候选局面：我方三个单位的落点
	var boards := [
		["原位置", [Vector2i(0, 1), Vector2i(4, 1), Vector2i(2, 1)]],
		["AI 本回合的落点", [Vector2i(3, 1), Vector2i(3, 2), Vector2i(2, 2)]],
	]
	for bd in boards:
		var cells: Array = bd[1]
		var descs: Array = [
			_desc(DataRegistry.Faction.ENEMY, "hero_10", cells[0], "白游侠"),
			_desc(DataRegistry.Faction.ENEMY, "hero_27", cells[1], "暗域"),
			_desc(DataRegistry.Faction.ENEMY, "hero_30", cells[2], "嬉皮死神"),
			_desc(DataRegistry.Faction.PLAYER, "hero_18", Vector2i(2, 6), "长剑"),
			_desc(DataRegistry.Faction.PLAYER, "hero_43", Vector2i(1, 6), "hero_43"),
			_desc(DataRegistry.Faction.PLAYER, "hero_40", Vector2i(0, 6), "红帽"),
		]
		var occ := {}
		for i in descs.size():
			occ[descs[i]["cell"]] = i
		var sim = ai.build_state(descs, occ, {}, {}, obst, {}, {})
		print("PROBE|===== %s =====" % bd[0])
		for i in 3:
			var u = sim.units[i]
			var rd: Array = ai._aoe_riders_on(sim, u, u.cell)
			var txt := ""
			for r in rd:
				txt += "%s=%.2f  " % [r[0], r[1]]
			print("PROBE|  %-8s @%s ⇒ %s" % [u.name, str(u.cell), ("（无）" if txt == "" else txt)])
		print("PROBE|  ㉛ 总账 _aoe_rider_total = %.2f（W=%.1f）" % [ai._aoe_rider_total(sim), ai.w_aoe_rider_total])
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
	return d if d is Dictionary else {}
