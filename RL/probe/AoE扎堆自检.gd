extends Node
## 【2026-09-26 一次性探针·临时】**AoE 规避第一批**自检 —— 用户从四选一里挑了「先做白游侠+长剑两种」：
##   「按对手实际有的 AoE 形状罚扎堆」= 把它打我队友时、**我因为站在旁边 / 身后而多挨的那一下**
##   折进「挨打合计」（于是 ⑥/⑦/⑮ 与日志 `阈值比较` 一起变）。
##
## 三块 7×5 盘面（都只读、不改生产）：
##   A **白游侠散射 · 我方两人相邻**（格距 1）⇒ 两个人**各**多挨一笔 `白游侠散射N`
##     （每个对手每回合只出手一次 ⇒ 这笔是"它打另一个、溅到我"）。
##   A2 **对照 · 我方两人格距 2**（不邻）⇒ 只该有正常的 `白游侠N` 普攻，**没有** `散射` 那一笔。
##   B **长剑剑气 · 站在队友身后同一条射线上**（含一个不在射线上的对照 丙）⇒ 乙多一笔 `长剑剑气N`，丙没有。
##
## 输出：每行 `AOE|...`，末尾 `AOE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var w := _load_flat_weights(NIGHTMARE_PATH)
	var ai = _mk_ai(w)
	print("AOE|CFG|fork=%s|w=%s" % [_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH)])
	if not ai.has_method("_aoe_riders_on"):
		print("AOE|GUARD|FAIL|fork 里没有 _aoe_riders_on ⇒ AoE 这一批没同步进 fork（重建后重跑）")
		get_tree().quit(1)
		return
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	# A 白游侠散射：我方甲(3,1) 与 乙(3,2) **相邻**
	_panel(ai, "A 白游侠·我方相邻(格距1)", [
		_u(E, "hero_26", Vector2i(3, 1), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(3, 2), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(P, "hero_10", Vector2i(3, 4), 20, 20, 5, 3, 2, RANGED, [], "白游侠"),
	])
	# A2 对照：两人格距 2 ⇒ 不该有散射那一笔
	_panel(ai, "A2 对照·我方格距2（不邻）", [
		_u(E, "hero_26", Vector2i(3, 1), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(3, 3), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(P, "hero_10", Vector2i(3, 4), 20, 20, 5, 3, 2, RANGED, [], "白游侠"),
	])
	# B 长剑剑气：乙(2,3) 站在 甲(2,2) 身后同一条射线上（长剑从 (2,1) 砍甲）；丙(4,2) 不在射线上
	_panel(ai, "B 长剑剑气·身后直线", [
		_u(E, "hero_26", Vector2i(2, 2), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(2, 3), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(E, "hero_16", Vector2i(4, 2), 20, 20, 5, 3, 1, MELEE, [], "我方丙"),
		_u(P, "hero_18", Vector2i(2, 0), 20, 20, 6, 3, 1, MELEE, [], "长剑"),
	])
	# C 对手红帽的扑街自爆（2026-09-27 加）：她血低到"一碰就死"时，**挨着她的我方单位**要多记 13
	_panel(ai, "C1 红帽血5(一碰就死)·两人挨着她 + 一人离两格", [
		_u(E, "hero_26", Vector2i(2, 3), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(1, 4), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(E, "hero_16", Vector2i(4, 2), 20, 20, 5, 3, 1, MELEE, [], "我方丙"),
		_u(P, "hero_40", Vector2i(2, 4), 5, 13, 4, 3, 1, MELEE, [], "红帽"),
	])
	_panel(ai, "C2 红帽血20(打不死)·同样站位", [
		_u(E, "hero_26", Vector2i(2, 3), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(1, 4), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(P, "hero_40", Vector2i(2, 4), 20, 20, 4, 3, 1, MELEE, [], "红帽"),
	])
	_panel(ai, "C3 红帽血5 但被沉默 ⇒ 不炸", [
		_u(E, "hero_26", Vector2i(2, 3), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_23", Vector2i(1, 4), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(P, "hero_40", Vector2i(2, 4), 5, 13, 4, 3, 1, MELEE, [], "红帽", {"silenced": true}),
	])
	print("AOE|END")
	get_tree().quit(0)

func _panel(ai, tag: String, descs_in: Array) -> void:
	var descs: Array = descs_in
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	for u in sim.units:
		if u == null or not u.alive:
			continue
		print("AOE|%s|盘面|%s|fn=%d|%s|hp=%d|eatk=%.0f|emove=%d|range=%d|type=%d|技能=%s" % [tag, str(u.name),
			int(u.fn), str(u.cell), int(u.hp), float(u.eatk), int(u.emove), int(u.atk_range),
			int(u.atk_type), str(u.skills)])
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var o := {}
		var inc := float(ai._incoming_total_on(sim, u, u.cell, o))
		print("AOE|%s|%s|%s|挨打合计=%.1f|逐笔=%s" % [tag, str(u.name), str(u.cell), inc, _fmt(o)])

func _fmt(o: Dictionary) -> String:
	var bits: Array[String] = []
	for row in (o.get("parts", []) as Array):
		var r: Array = row
		bits.append("%s%.0f" % [String(r[0]), float(r[1])])
	return ("(" + "＋".join(bits) + ")") if bits.size() > 0 else "∅"

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}
	for k in extra.keys():
		d[String(k)] = extra[k]
	return d

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	return ai

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
		if String(k).begins_with("_"):
			continue
		out[String(k)] = (d as Dictionary)[k]
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
