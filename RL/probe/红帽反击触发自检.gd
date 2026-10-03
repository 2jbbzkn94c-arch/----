extends Node
## 【2026-10-03 一次性探针·只读】红帽自爆那一族在 **T147** 之后的"圈里到底谁需要躲"。
##   用户口径：「她已经在安全血线附近时**不需要所有人都避**，只要注意**反击会把她降到安全血线的那个英雄**。」
##   ⇒ ㉛ 只给**反击触发器**收费：她够得到它 · 这一下打不死它 · 它的反击 ≥ `her.hp − 安全血线`。
## 合成盘（5×7 · 只为读数）：
##   · 我方 **重拳**（hero_49 人造：hp 30 / atk 4 / 近战 / 射程 1 / 移动 2）摆在**她贴身**处（d=1）
##   · 我方 **轻手**（同一模板 · atk 1）摆在 **d=2**（她 mv 2 ⇒ 走一步够得到）
##   · 玩家红帽 hero_40 在 (2,3) · `max_hp` 12 · 攻 5（面板事实）· mv 2
##   六臂：A 她 8 血（= 线+4）· B 她 4 血（≤ 线）· C 她 12 血 · D 她 8 血但重拳只有 3 血（她一发打死它 ⇒ 无反击）·
##        E 她 8 血但移动力 0（钉住 ⇒ 走不到轻手）· F 她 8 血 + 被[沉默]。
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

	var her_cell: Vector2i = Vector2i(2, 3)
	# 探路盘：量各格到她（她占 (2,3)、其余空）
	var probe_descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", Vector2i(0, 0), "探路"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var sim0 = ai.build_state(probe_descs, { Vector2i(0, 0): 0, her_cell: 1 }, {}, {}, {}, {}, {})
	var c1: Vector2i = Vector2i(-9, -9)
	var c2: Vector2i = Vector2i(-9, -9)
	for c in _grid.all_cells():
		if c == her_cell or c == Vector2i(0, 0):
			continue
		var d: int = ai.walk_dist(sim0, her_cell, c)
		if d == 1 and c1.x < 0:
			c1 = c
		elif d == 2 and c2.x < 0:
			c2 = c
	print("PROBE|代表格：贴身 d=1 → %s · d=2 → %s（她 mv 2 ⇒ 走一步够得到）" % [str(c1), str(c2)])

	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", c1, "重拳"),
		_desc(DataRegistry.Faction.ENEMY, "hero_49", c2, "轻手"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var sim = ai.build_state(descs, { c1: 0, c2: 1, her_cell: 2 }, {}, {}, {}, {}, {})
	var heavy = sim.units[0]
	var light = sim.units[1]
	var her = sim.units[2]
	heavy.max_hp = 30; heavy.atk = 4; heavy.eatk = 4
	heavy.atk_range = 1; heavy.atk_type = DataRegistry.AttackType.MELEE
	heavy.move = 2; heavy.emove = 2
	light.max_hp = 30; light.atk = 1; light.eatk = 1
	light.atk_range = 1; light.atk_type = DataRegistry.AttackType.MELEE
	light.move = 2; light.emove = 2
	her.max_hp = 12; her.atk = 5; her.eatk = 5
	her.atk_range = 1; her.atk_type = DataRegistry.AttackType.MELEE
	her.move = 2; her.emove = 2

	var line: float = ai._redcap_kill_line(sim, her)
	print("PROBE|安全血线（我方对她最大单击）= **%.2f**（重拳 %s）· 危险门（×%.1f）= %.2f" % [
		line, str(heavy.cell), AI_SRC.REDCAP_NEAR_LINE_MULT, line * AI_SRC.REDCAP_NEAR_LINE_MULT])
	print("PROBE|反击量（她贴身打过来时）：重拳 %.2f · 轻手 %.2f" % [
		ai._redcap_counter_dmg(sim, heavy, her), ai._redcap_counter_dmg(sim, light, her)])

	var arms: Array = [
		["A 她 8 血（线 + 4）⇒ 重拳应触发、**轻手不该收**", 8, 30, 2, false],
		["B 她 4 血（≤ 线）⇒ 两个都触发", 4, 30, 2, false],
		["C 她 12 血（> 线 + 4）⇒ 都不触发", 12, 30, 2, false],
		["D 她 8 血 · 重拳只有 3 血（她一发打死它 ⇒ 无反击）", 8, 3, 2, false],
		["E 她 8 血 · 她移动力 0（钉住 ⇒ 走不到轻手）", 8, 30, 0, false],
		["F 她 8 血 · 她被[沉默]", 8, 30, 2, true],
		["G 她 1 血（任何打得动的反击都能收尾）⇒ 两个都会触发", 1, 30, 2, false],
	]
	for arm in arms:
		her.hp = int(arm[1])
		heavy.hp = int(arm[2])
		her.emove = int(arm[3])
		her.silenced = bool(arm[4])
		var txt := ""
		for pair in [[heavy, "重拳"], [light, "轻手"]]:
			var u = pair[0]
			var trig: bool = ai._redcap_counter_trigger(sim, her, u)
			var rd: Array = ai._aoe_riders_on(sim, u, u.cell)
			var v := 0.0
			for r in rd:
				v = maxf(v, float(r[1]))
			txt += "%s[反击%.2f 触发器=%s 收=%.2f]  " % [
				pair[1], ai._redcap_counter_dmg(sim, u, her), "是" if trig else "否", v]
		print("PROBE|===== %s =====" % arm[0])
		print("PROBE|  她 hp=%d mv=%d 沉默=%s ⇒ %s㉛ 项=%.2f" % [
			her.hp, her.emove, str(her.silenced), txt, ai._aoe_rider_total(sim)])
		her.silenced = false
		heavy.hp = 30
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
