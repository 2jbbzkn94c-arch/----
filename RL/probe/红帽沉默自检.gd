extends Node
## 【2026-09-26 一次性探针·临时】红帽（hero_40）**被沉默威胁时的行为**自检 ——
##   用户实机原话：「红帽还是送，在对方有沉默的时候，AI 应该要尽可能地保护红帽不被沉默，
##   即使被沉默了，也不能受到巨额伤害」。
##
## 盘面：我方（AI）红帽(2,4)**只剩 6 血** + 队友塔盾(0,6)（远处，避免队形项干扰）；
##   玩家：沉默术士 hero_34(2,1) · 火枪手 hero_09(0,4)（远程 4 攻）· 长剑 hero_18(4,4)。
##   ⇒ 她**留在原地**时：全额挨打合计 ≥ 她的血（会被打死），而且两条命脉（自爆）被沉默掐住。
##   ⇒ 正确行为 = 退到"沉默者够不到 / 挨打合计 < 她的血"的格子（哪怕这一回合不出手）。
##
## 三臂：`w0` = 红帽五键全关（= 今天生产基线）· `sil15` = 只开 ③=1.5（旧口径的力度）· `sil3` = ③=3.0。
## 每臂跑**真 search**（模式 2、beam 400），打印她的落点/是否出手/终局分/五项分账，
##   以及**她落点上**的「全额挨打合计」与「沉默者够不够得到」—— 这两条就是 ③ 的输入。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	print("PROBE|CFG|盘面：红帽6血(2,4) · 塔盾(0,6) ｜ 玩家：沉默术士(2,1) 火枪手(0,4) 长剑(4,4)")
	_arm("w0（红帽键全关 = 生产基线）", {})
	_arm("③=1.5（旧力度）", { "REDCAP_SILENCE_GUARD_W": 1.5 })
	_arm("③=3.0", { "REDCAP_SILENCE_GUARD_W": 3.0 })
	_arm("③=3.0 + 血线=1.0（两条一起开）", { "REDCAP_SILENCE_GUARD_W": 3.0, "REDCAP_HP_FLOOR_W": 1.0 })
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, w40: Dictionary) -> void:
	var descs: Array = []
	var cap := _desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 4), "红帽")
	cap["hp"] = 6
	descs.append(cap)
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_11", Vector2i(0, 6), "塔盾"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_34", Vector2i(2, 1), "沉默术士"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(0, 4), "火枪手"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_18", Vector2i(4, 4), "长剑"))
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 30000
	ai.set_weights({ "hero_40": w40 })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	# 起点：她原地时的那两条输入
	var sil0 = sim.units[2]
	var inc0: float = ai._incoming_total_on(sim, sim.units[0], sim.units[0].cell)
	var reach0: bool = ai._threat_can_hit(sim, sil0, sim.units[0].cell, sim.units[0])
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var end = sim.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var body := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		if String(sim.units[idx].hero_id) != "hero_40":
			continue
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		body = "落点=%s，%s" % ["原地" if mv == null else str(mv), "出手打 " + String(sim.units[atk].hero_id) if atk >= 0 else "不出手"]
	# 末态：她落点上那两条输入 + 分账
	var ecap = end.units[0]
	var esil = end.units[2]
	var inc1: float = ai._incoming_total_on(end, ecap, ecap.cell)
	var reach1: bool = ai._threat_can_hit(end, esil, ecap.cell, ecap)
	# 逐敌诊断：末态她落点上，每个敌人"能不能打、打多少"（解释那个合计为什么是那个数）
	var diag: Array[String] = []
	for i in end.units.size():
		var atk_u = end.units[i]
		if atk_u.fn == ecap.fn or not atk_u.alive:
			continue
		var d: int = _grid.distance(atk_u.cell, ecap.cell)
		var can: bool = ai._threat_can_hit(end, atk_u, ecap.cell, ecap)
		var raw: float = ai._threat_hit_value(end, atk_u, d, false) + float(ai._sim_turn_start_atk_bonus(end, atk_u))
		raw *= float(ai._sim_mult_at(end, atk_u, ecap, ecap.cell))
		var one: float = ai._hit_after_target_mods(end, ecap, ecap.cell, raw)
		diag.append("%s d%d 能打=%s 单击=%.1f" % [String(atk_u.hero_id), d, str(can), one])
	var terms: Dictionary = ai._redcap_terms(end) if ai._redcap_on() else {}
	var shown := "（不进分账）"
	if not terms.is_empty():
		shown = "血线=%.2f 替补=%.2f 沉默=%.2f 蓄爆=%.2f 止损=%.2f" % [
			float(terms.get("血线", 0.0)), float(terms.get("替补风险", 0.0)), float(terms.get("沉默风险", 0.0)),
			float(terms.get("蓄爆", 0.0)), float(terms.get("止损", 0.0))]
	# 末态逐单位（便于手核"为什么那个合计是 0"）
	var dump: Array[String] = []
	for i in end.units.size():
		var eu = end.units[i]
		dump.append("%s@%s hp%d/%d%s" % [String(eu.hero_id), str(eu.cell), int(eu.hp), int(eu.max_hp),
			"" if eu.alive else "☠"])
	print("PROBE|%s|末态单位：%s" % [tag, "、".join(dump)])
	print("PROBE|%s|逐敌：%s｜开火位数=%d" % [tag, " ／ ".join(diag), int(ai._threat_slots(end, ecap, ecap.cell))])
	print("PROBE|%s|起点：全额合计=%.1f 沉默者够得到=%s ｜**红帽 %s**｜末态：全额合计=%.1f 沉默者够得到=%s｜%s｜终局分=%.2f" % [
		tag, inc0, str(reach0), (body if body != "" else "本回合没动作"), inc1, str(reach1), shown,
		float(ai._evaluate(end, true))])

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

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
