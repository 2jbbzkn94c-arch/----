extends Node
## 【2026-09-24 一次性探针】用户实机：「炸弹人为什么不往后退打 3 伤，而是原地打 1 伤」
##
## 机制：炸弹人(hero_35) = 攻 3 · **〈远程〉** ⇒ 贴身那一枪被压成 1、退开一格就是 3。
## 病灶（已修）：阶段 1 的 `_tp_move_actions()` 只过滤"移动落点"，"原地"被无条件保留
##   ⇒ 落点定在原点 ⇒ 阶段 2 里它已 moved ⇒ `_actions_for()` 不再给移动候选 ⇒ `alt_best` 恒 0
##   ⇒ `_ranged_pinned_shot_ok()` 失效 ⇒ 只能"原地打 1 伤"。
##
## 本探针：造"炸弹人贴着嘲讽者(雪拳)、身后有空位"的局面，然后
##   ① 打印 `_tp_move_actions()` 给出的落点（修后：**不含"原地"**，除非这一击能击杀）；
##   ② 打印 `_actions_for()` 的攻击候选与各自伤害（原地=1 / 退开=3）；
##   ③ 真跑 `search()` 并结算终局分 ⇒ 看计划是不是"退开打 3"。
##
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
	print("PROBE|CFG|fork=%s|SEARCH_MODE=%s|ENGAGE_PULL_PER_CELL=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), str(_nm.get("ENGAGE_PULL_PER_CELL", 0))])
	var descs: Array = []
	# AI 侧：炸弹人(攻3·远程) 贴着 雪拳；旁边一个队友，保证它退开不会变成孤军
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_35", Vector2i(2, 3), "炸弹人"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_46", Vector2i(1, 3), "宿魂"))
	# 玩家侧：雪拳(嘲讽·26血) 在正上方 ⇒ 与炸弹人相邻；另两个离远，避免干扰
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_26", Vector2i(2, 2), "雪拳"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_20", Vector2i(4, 0), "赏金猎人"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_06", Vector2i(0, 0), "医护兵"))
	var built := _build(descs)
	var ai = built["ai"]
	var sim = built["sim"]
	var bi := 0
	for i in sim.units.size():
		var u = sim.units[i]
		print("PROBE|盘面|%s%s@%s|面板攻=%d 有效攻=%d hp=%d 射程=%d" % [
			("AI " if u.fn == DataRegistry.Faction.ENEMY else "玩家"), String(u.name), str(u.cell),
			int(u.atk), int(u.eatk), int(u.hp), int(u.atk_range)])
		if String(u.hero_id) == "hero_35":
			bi = i
	var bomb = sim.units[bi]
	print("PROBE|炸弹人@%s|贴身(与敌相邻)=%s|贴身后这一枪=%d|退开后这一枪=%d" % [
		str(bomb.cell), str(ai._sim_enemy_adjacent(sim, bomb, bomb.cell)),
		int(ai._sim_pinned_atk(bomb)), int(ai._sim_free_atk(bomb))])
	# ① 阶段 1 的落点候选
	var cells: Array = []
	for a in ai._tp_move_actions(sim, bi):
		cells.append("原地" if a.get("move") == null else str(a["move"]))
	print("PROBE|阶段1落点|%s" % " , ".join(cells))
	# ② `_actions_for` 的攻击候选 + 伤害
	for combo in ai._actions_for(sim, bi):
		var ti := int(combo.get("atk", -1))
		if ti < 0:
			continue
		var fc: Vector2i = bomb.cell if combo.get("move") == null else combo["move"]
		var t = sim.units[ti]
		var free: bool = not ai._sim_enemy_adjacent(sim, bomb, fc)
		var dmg := int(ai._sim_free_atk(bomb)) if free else int(ai._sim_pinned_atk(bomb))
		print("PROBE|候选|开火格=%s 目标=%s|%s ⇒ 预计 %d 伤" % [
			str(fc), String(t.name), ("自由(不贴身)" if free else "**贴身**"), dmg])
	# ③ 真跑搜索
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var ti2 := int(act.get("atk", -1))
		var tn := "-"
		if ti2 >= 0:
			tn = String(sim.units[ti2].name)
		txt += "%s[%s->%s,atk=%s] " % [String(sim.units[idx].name), str(sim.units[idx].cell),
			("原地" if act.get("move") == null else str(act["move"])), tn]
	print("PROBE|计划|%s" % txt)
	var post = sim.clone()
	for st in plan:
		ai._apply(post, int(st["idx"]), st["action"])
	print("PROBE|结算|终局分=%.2f|雪拳剩血=%d|炸弹人最后在=%s" % [
		float(ai._evaluate(post, true)), int(post.units[2].hp), str(post.units[bi].cell)])
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
