extends Node
## 【2026-09-24 一次性探针】用户：「为什么还是存在锤头鲨攻击顺序在队友前面的？打的是同一个人，反击已经被用掉了」。
##
## 机制：锤头鲨(hero_37) = **我方回合内，每当敌人受到一次伤害，自己攻击力 +1**（`heroes/hero_37_锤头鲨.gd`）。
##   ⇒ 它**越晚出手越疼**（队友先打，它吃满 +N 再打）。所以"锤头鲨排在队友前面"只有在
##   **顺序对分数无影响**（目标反正死/反正溢出）时才无害。
##
## 查什么：造一个"三个 AI 单位都能打到同一个高血目标"的干净盘面，然后
##   ① 真跑 `search()`，看计划把锤头鲨排第几；
##   ② 把同一份计划的**攻击步**按三种顺序重放（原顺序 / 锤头鲨最先 / 锤头鲨最后），
##      用 `_evaluate(…, true)` 比分 ⇒ 直接回答"搜索选的顺序是不是更差的那个"。
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
	print("PROBE|CFG|fork=%s|SEARCH_MODE=%s|BEAM=%s|TWO_PHASE_DEDUP=%s" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), str(_nm.get("BEAM", 0)),
		str(_nm.get("TWO_PHASE_DEDUP", 0))])
	var descs: Array = []
	# AI 侧：锤头鲨(面板攻2) + 独脚龟(攻2) + 鼠队长(攻4)，三者都与玩家目标相邻
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_37", Vector2i(2, 1), "锤头鲨"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_13", Vector2i(1, 1), "独脚龟"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_04", Vector2i(3, 1), "鼠队长"))
	# 玩家侧：巨剑 24 血（三下打不死 ⇒ 顺序差异会体现在总伤害上）+ 远处一个波盾
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_12", Vector2i(2, 2), "巨剑"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(4, 4), "波盾"))
	var built := _build(descs)
	var ai = built["ai"]
	var sim = built["sim"]
	for i in sim.units.size():
		var u = sim.units[i]
		print("PROBE|盘面|%s%s@%s|面板攻=%d 有效攻=%d hp=%d/%d" % [
			("AI " if u.fn == DataRegistry.Faction.ENEMY else "玩家"), String(u.name), str(u.cell),
			int(u.atk), int(u.eatk), int(u.hp), int(u.max_hp)])
	var hh_idx := 0
	for i in sim.units.size():
		if String(sim.units[i].hero_id) == "hero_37":
			hh_idx = i
	# ① 真跑搜索
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var txt := ""
	var atk_steps: Array = []
	for j in plan.size():
		var st: Dictionary = plan[j]
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var ti := int(act.get("atk", -1))
		var tn := "-"
		if ti >= 0:
			tn = String(sim.units[ti].name)
			atk_steps.append(j)
		txt += "%s[%s->%s,atk=%s] " % [String(sim.units[idx].name), str(sim.units[idx].cell),
			("原地" if act.get("move") == null else str(act["move"])), tn]
	print("PROBE|计划|%s" % txt)
	print("PROBE|攻击步数=%d|锤头鲨在攻击序列里的位置=%d" % [
		atk_steps.size(), atk_steps.find(_step_of(plan, hh_idx)) + 1])
	# ② 三种顺序重放
	var r_base := _run_order(ai, sim, plan, atk_steps)
	print("PROBE|顺序·原计划|分=%.2f|锤头鲨出手时有效攻=%d|玩家剩血 %s" % [
		r_base["score"], r_base["hh_atk"], r_base["hp"]])
	var first_order := _reorder(atk_steps, _step_of(plan, hh_idx), true)
	var last_order := _reorder(atk_steps, _step_of(plan, hh_idx), false)
	var r_first := _run_order(ai, sim, plan, first_order)
	var r_last := _run_order(ai, sim, plan, last_order)
	print("PROBE|顺序·锤头鲨最先|分=%.2f|锤头鲨出手时有效攻=%d|玩家剩血 %s" % [
		r_first["score"], r_first["hh_atk"], r_first["hp"]])
	print("PROBE|顺序·锤头鲨最后|分=%.2f|锤头鲨出手时有效攻=%d|玩家剩血 %s" % [
		r_last["score"], r_last["hh_atk"], r_last["hp"]])
	var best := maxf(float(r_first["score"]), float(r_last["score"]))
	var chosen_is_best: bool = float(r_base["score"]) >= best - 0.001
	print("PROBE|判定|搜索选的顺序是否已是最优=%s（最优=%.2f，选=%.2f，差 %.2f）" % [
		str(chosen_is_best), best, r_base["score"], best - r_base["score"]])
	print("PROBE|END")
	get_tree().quit(0)

func _step_of(plan: Array, idx: int) -> int:
	for j in plan.size():
		if int((plan[j] as Dictionary)["idx"]) == idx \
				and int(((plan[j] as Dictionary)["action"] as Dictionary).get("atk", -1)) >= 0:
			return j
	return -1

func _reorder(atk_steps: Array, hh_step: int, first: bool) -> Array:
	var rest: Array = []
	for j in atk_steps:
		if int(j) != hh_step:
			rest.append(j)
	var out: Array = []
	if hh_step >= 0:
		if first:
			out.append(hh_step)
		out.append_array(rest)
		if not first:
			out.append(hh_step)
	else:
		out = atk_steps.duplicate()
	return out

func _run_order(ai, sim, plan: Array, atk_order: Array) -> Dictionary:
	var s = sim.clone()
	# 非攻击步（走位）先按原顺序跑完
	for st in plan:
		if int((st["action"] as Dictionary).get("atk", -1)) < 0:
			ai._apply(s, int(st["idx"]), st["action"])
	var hh_atk := -1
	for j in atk_order:
		var st2: Dictionary = plan[int(j)]
		var idx2 := int(st2["idx"])
		var act2: Dictionary = st2["action"]
		if String(s.units[idx2].hero_id) == "hero_37":
			hh_atk = int(s.units[idx2].eatk)
		ai._apply(s, idx2, act2)
	var hp := ""
	for i in s.units.size():
		var u = s.units[i]
		if u.fn != DataRegistry.Faction.ENEMY:
			hp += "%s=%d " % [String(u.name), int(u.hp)]
	return { "score": float(ai._evaluate(s, true)), "hp": hp, "hh_atk": hh_atk }

# ---------------------------------------------------------------- 工具（照搬 锤头鲨不前进自检.gd）
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
