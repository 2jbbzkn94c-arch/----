extends Node
## 【2026-09-29 一次性探针·只读】**替补「合力斩杀」**自检 —— 用户口径：
##   「如果对方已经死了两人，并且最后一人血量小于下回合 AI 和替补一起能造成的伤害，首要需求就是斩杀」。
##
## 四块盘面（都只读、不改生产；权重取 `RL/weights/噩梦.json` ⇒ `SUB_FINISH_W = 500` 是开的）：
##   A **合力斩杀**：对面最后一人 9 血，我方两人各 5 攻（谁都单收不了）、替补 4 攻
##     ⇒ 旧判据（`面板攻击力 ≥ 血`）判不出来；新的 `sub_kill_scan()` 应给出「合力收」（solo=false）。
##   B **真实一击·坚固**：目标 5 血带 [坚固] + 替补 5 攻（真实一击 4）
##     ⇒ 旧判据会误判"能一刀收"；新的应判"收不掉"（扫描返回空）。
##   C **真实一击·圣盾**：目标 5 血带 [圣盾] + 替补 6 攻（面板够、但那刀被盾吃掉）
##     ⇒ 同上：扫描应返回空。
##   D **落点打分**：`pick_sub_cell()` 在"对面只剩 1 人"时给"能打到它 / 合力能杀 / 单独能杀"三档
##     （噩梦 `w_sub_finish_w = 500`）—— 打印每个合法落点到目标的距离，看它选哪一格。
##   E **单独收那一档还在**（且排在"合力收"前面）：目标 5 血无盾 + 替补 5 攻 ⇒ solo=true。
##
## 输出：每行 `FIN|...`，末尾 `FIN|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var ai = _mk_ai(_load_flat_weights(NIGHTMARE_PATH))
	print("FIN|CFG|fork=%s|w=%s|SUB_FINISH_W=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH), str(ai.w_sub_finish_w)])
	if not ai.has_method("sub_kill_scan"):
		print("FIN|GUARD|FAIL|fork 里没有 sub_kill_scan ⇒ 重建后重跑")
		get_tree().quit(1)
		return
	var P := DataRegistry.Faction.PLAYER
	var E := DataRegistry.Faction.ENEMY
	var MELEE := int(DataRegistry.AttackType.MELEE)
	# A 合力斩杀：我方两人各 5 攻（都不够 9 ⇒ 谁都不能单独收），替补 4 攻
	var simA = _sim(ai, [
		_u(E, "hero_26", Vector2i(3, 1), 26, 26, 5, 3, 1, MELEE, [], "我方甲"),
		_u(E, "hero_16", Vector2i(1, 1), 20, 20, 5, 3, 1, MELEE, [], "我方乙"),
		_u(P, "hero_23", Vector2i(3, 3), 9, 20, 5, 3, 1, MELEE, [], "玩家最后一人"),
	])
	_panel(ai, simA, "A 合力斩杀（两人各5攻 + 替补4攻 · 目标9血）", ["hero_40"], [Vector2i(2, 2), Vector2i(2, 1)])
	# B 坚固：目标 5 血带 [坚固]、替补 5 攻（面板 5 ≥ 5 ⇒ 旧判据说"能一刀收"，真实一击 4 ⇒ 收不掉）
	var simB = _sim(ai, [
		_u(E, "hero_26", Vector2i(0, 0), 26, 26, 0, 1, 1, MELEE, [], "我方甲(0攻·不参与)"),
		_u(P, "hero_23", Vector2i(3, 3), 5, 20, 5, 3, 1, MELEE, [], "玩家最后一人", {"solid": true}),
	])
	_panel(ai, simB, "B 坚固（目标5血带坚固 · 替补hero_40面板5攻 ⇒ 真实一击4）", ["hero_40"], [Vector2i(2, 2)])
	# C 圣盾：目标 5 血带 [圣盾]、替补 5 攻（面板够，但那刀被盾整次吃掉 ⇒ 收不掉）
	var simC = _sim(ai, [
		_u(E, "hero_26", Vector2i(0, 0), 26, 26, 0, 1, 1, MELEE, [], "我方甲(0攻·不参与)"),
		_u(P, "hero_23", Vector2i(3, 3), 5, 20, 5, 3, 1, MELEE, [], "玩家最后一人", {"shield": true}),
	])
	_panel(ai, simC, "C 圣盾（目标5血带圣盾 · 替补hero_40面板5攻）", ["hero_40"], [Vector2i(2, 2)])
	# D 落点打分：**替补单独收不掉、但合力能收**（目标 9 血）时，`pick_sub_cell()` 该不该为它摆位
	_cells_dump(ai, simA, "D 落点打分（目标9血 · 我方合计10 · 替补5攻 ⇒ 只能合力收）", "hero_40",
			[Vector2i(2, 2), Vector2i(1, 1), Vector2i(1, 3), Vector2i(5, 1)], simA.units[2].cell)
	# E 单独收那一档还在（且排在"合力收"前面）：目标 5 血无盾、替补 5 攻能一刀收 ⇒ solo=true
	var simE = _sim(ai, [
		_u(E, "hero_26", Vector2i(0, 0), 26, 26, 0, 1, 1, MELEE, [], "我方甲(0攻·不参与)"),
		_u(P, "hero_23", Vector2i(3, 3), 5, 20, 5, 3, 1, MELEE, [], "玩家最后一人"),
	])
	_panel(ai, simE, "E 单独收（目标5血无盾 · 替补hero_40面板5攻）", ["hero_40", "hero_18"], [Vector2i(2, 2)])
	print("FIN|END")
	get_tree().quit(0)

## 打印一个盘面的 `sub_kill_scan()` 结果（`{}` = 判"收不掉"）
func _panel(ai, sim, tag: String, cands: Array, cells: Array) -> void:
	for uid in cands:
		var d = DataRegistry.get_hero(String(uid))
		print("FIN|%s|候选|%s|面板攻=%d|出生移动=%d|出生射程=%d" % [tag, String(uid),
			int(d.atk), DataRegistry.spawn_move(d), DataRegistry.spawn_attack_range(d)])
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive:
			continue
		print("FIN|%s|盘面|%s|格=%s|血=%d/%d|攻=%d|移动=%d|射程=%d|坚固=%s|盾=%s" % [tag, str(u.name),
			str(u.cell), int(u.hp), int(u.max_hp), int(u.atk), int(u.emove), int(u.atk_range),
			str(bool(u.solid)), str(bool(u.shield))])
	var plan: Dictionary = ai.sub_kill_scan(sim, cands, cells)
	if plan.is_empty():
		print("FIN|%s|结论|❌ 收不掉（scan 返回空 ⇒ 动态替补会退回 ②救人 / ③需求档）" % tag)
		return
	print("FIN|%s|结论|✅ %s → 上 %s 落 %s｜需要 %.1f = 队友 %.1f + 替补 %.1f（合计 %.1f，余量 %.1f）｜对面剩 %d 人｜rank=%.0f" % [
		tag, ("单独收" if bool(plan["solo"]) else "合力收"), String(plan["hero"]), str(plan["cell"]),
		float(plan["need"]), float(plan["team"]), float(plan["sub"]), float(plan["total"]),
		float(plan["total"]) - float(plan["need"]), int(plan["foe_alive"]), float(plan["rank"])])

## 逐格打印 `pick_sub_cell()` 的选择（含每格到目标的距离，看它为什么选那一格）
## + `pick_sub_hero()` 在预设名单里的选择。
func _cells_dump(ai, sim, tag: String, hero_id: String, cells: Array, tgt: Vector2i) -> void:
	var pick: Vector2i = ai.pick_sub_cell(sim, hero_id, cells)
	print("FIN|%s|pick_sub_cell(%s)=%s ← 目标在 %s" % [tag, hero_id, str(pick), str(tgt)])
	for c in cells:
		var one: Array = [c]
		print("FIN|%s|单格试探|%s|距目标=%d|pick_sub_cell=%s" % [
			tag, str(c), ai.approach_dist(sim, c, tgt), str(ai.pick_sub_cell(sim, hero_id, one))])
	var roster: Array = ["hero_18", "hero_40"]
	print("FIN|%s|pick_sub_hero(%s)=%s" % [tag, str(roster), String(ai.pick_sub_hero(sim, roster, cells))])

func _sim(ai, descs_in: Array):
	var descs: Array = descs_in
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return ai.build_state(descs, occ, {}, {}, {}, {}, {})

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
