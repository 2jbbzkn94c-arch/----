extends Node
## 【2026-10-02·一次性探针·只读·用户「怎么计算挨远程打的时候，又计算成被贴边的了？远程是可以退后打满伤害的，
##   除非没有能打满伤害的位置」】
##
## 复刻用户那局的转储（界面坐标 → 内部 = −1；单位位置取那条 AI 计划**走完之后**的落点）：
##   AI(ENEMY)：小阴影 hero_15 @(0,5) 血9 中毒 · 黄金矿工 hero_42 @(2,4) 血20 · 复仇者 hero_23 @(1,4) 血15 中毒
##   玩家(PLAYER)：毒蛇淑女 hero_03 @(0,4) 血8 · 装甲堡垒 hero_48 @(2,3) 血28 [坚固] · 火枪手 hero_09 @(3,3) 血20 [圣盾]
## （日志里「火枪手1」那一笔 = 被贴身压到 1；本探针问：它到底退不退得掉、退开之后打不打得到。）
##
## 输出：RN|… / RN|END

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_15", Vector2i(0, 5), "小阴影"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_42", Vector2i(2, 4), "黄金矿工"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_23", Vector2i(1, 4), "复仇者"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_03", Vector2i(0, 4), "毒蛇淑女"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_48", Vector2i(2, 3), "装甲堡垒"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(3, 3), "火枪手"))
	descs[0]["hp"] = 9
	descs[0]["poisoned"] = true
	descs[2]["hp"] = 15
	descs[2]["poisoned"] = true
	descs[4]["solid"] = true
	descs[5]["shield"] = true
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var gunner = null      # 火枪手（远程 4 攻 / 射程 2 / 移动 2）
	for u in sim.units:
		if u.hero_id == "hero_09":
			gunner = u
	# ① 每个 AI 单位那两行（日志里的"下回合在这一格会挨 N 伤（…）"）
	for ti in [0, 1, 2]:
		var t = sim.units[ti]
		var info := {}
		var inc: float = ai._incoming_total_on(sim, t, t.cell, info)
		var parts: Array[String] = []
		for row in (info.get("parts", []) as Array):
			var r: Array = row
			parts.append("%s=%.1f" % [String(r[0]), float(r[1])])
		var d: int = _grid.distance(gunner.cell, t.cell)
		print("RN|%s@%s|挨打合计=%.1f（%s）｜火枪手到它 d=%d 贴身=%s 退得掉=%s 退开能打=%s｜那一笔算出=%.1f（贴身值 %d / 满额 %d）" % [
			String(t.name), str(t.cell), inc, "、".join(parts), d,
			str(ai._sim_enemy_adjacent(sim, gunner, gunner.cell)), str(ai._sim_pin_escapable(sim, gunner)),
			str(ai._sim_pin_escape_fire_cell(sim, gunner, t.cell, t)),
			ai._threat_hit_value(sim, gunner, d, false, t.cell, t),
			int(ai._sim_pinned_atk(gunner)), int(ai._sim_free_atk(gunner))])
	# ② 火枪手"退得掉吗 / 哪几格能打满"：把所有走得到的格列出来
	var budget: int = ai._threat_emove_next(sim, gunner)
	var cells: Array = ai._sim_walk_cells(sim, gunner.cell, budget, gunner.skills.has(DataRegistry.Skill.INFILTRATE))
	var tgt = sim.units[2]      # 复仇者
	var rows: Array[String] = []
	for c in cells:
		var adj: bool = false
		for u2 in sim.units:
			if u2.alive and u2.fn == DataRegistry.Faction.ENEMY and _grid.distance(c, u2.cell) == 1:
				adj = true
				break
		var fire: bool = ai._threat_fire_ok_at(sim, gunner, c, tgt.cell, tgt)
		rows.append("%s[贴=%s 打复仇者=%s]" % [str(c), ("是" if adj else "否"), ("能" if fire else "不能")])
	print("RN|火枪手@%s 移动力=%d｜走得到的格共 %d 个：%s" % [
		str(gunner.cell), budget, cells.size(), " ".join(rows)])
	print("RN|结论|它现在贴不贴身=%s｜能不能找到「不贴任何我方单位」的落点=%s｜从那里能不能打到复仇者=%s" % [
		str(ai._sim_enemy_adjacent(sim, gunner, gunner.cell)), str(ai._sim_pin_escapable(sim, gunner)),
		str(ai._sim_pin_escape_fire_cell(sim, gunner, tgt.cell, tgt))])
	print("RN|END")
	get_tree().quit(0)

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := int(hd.move_range)
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove += 1
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
