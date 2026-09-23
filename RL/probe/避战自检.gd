extends Node
## 【2026-09-22 一次性探针】"能打到人却不打"复算 —— 跑完即退，**不改任何生产代码**。
##
## 要回答的两个实机案例（用户贴的决策日志）：
##   案例1：雪拳 (2,1)、移动 3、射程 1；玩家黄金矿工 (3,3)、攻 3。日志说"落点够得到0个 → 不攻击"，
##          但按棋盘几何它本来能走 2 步到 (3,2)/(2,3) 打到矿工。⇒ 查：候选表里到底有没有那两格、
##          每条候选的分数各是多少、`search()` 最后选了什么。
##   案例2：红帽 / 雪拳 原地就够得到复仇者（攻 2、血 26、<嘲讽>、反击无限且 2 倍），却选择不攻击。
##          ⇒ 查：打 vs 不打 的逐项差、以及 `IDLE_HIT_PENALTY`（能打不打罚 2 分）在搜索里到底有没有生效。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag avoid -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/避战自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。
##
## ⚠️ 本探针加载的是**噩梦档真正用的那份 fork**（`RL/ai/AI_Battle.gd`），并且从 `噩梦.json` 注入权重
##    ⇒ 打印出来的每一项差都是"游戏里真正生效的值"。`Sim` / `SimUnit` 是 fork 的内部类，
##    **不能写类型标注**（否则解析阶段就报 Could not find type，脚本不加载 ⇒ headless 永久挂住）。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var nm := _load_json(WEIGHTS)
	print("PROBE|CFG|weights=%s|keys=%d|fork=%s" % [WEIGHTS, nm.size(), _sha("res://RL/ai/AI_Battle.gd")])
	_case1(nm, false)
	_case1(nm, true)
	_case2(nm)
	print("PROBE|END")
	get_tree().quit(0)

# ---------------------------------------------------------------- 案例1：雪拳 vs 黄金矿工
func _case1(nm: Dictionary, extra_foe: bool) -> void:
	var tag := "C1b" if extra_foe else "C1"
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(0, 1), 13, 5, 2, "红帽我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 1), 26, 2, 3, "雪拳我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_43", Vector2i(4, 1), 14, 1, 2, "风语者我"))
	# 玩家：黄金矿工（基础攻 2 + 已吃 1 枚金矿 = 3 ⇒ 与日志的「黄金矿工3」对齐）
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_42", Vector2i(3, 3), 18, 3, 3, "矿工敌"))
	if extra_foe:
		var hd = DataRegistry.heroes["hero_09"]
		descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(2, 5), int(hd.max_hp), int(hd.atk), 2, "火枪手敌"))
	var ai = _mk_ai(nm)
	var built := _build(ai, descs)
	var sim = built["sim"]
	var snow := _find(sim, "雪拳我")
	var miner := _find(sim, "矿工敌")
	var su = sim.units[snow]
	print("PROBE|%s|cfg|idle=%.1f|risk=%.1f|riskpow=%.1f|deadfold=%.1f|pool=%.1f|escape=%.1f|cohesion=%.1f|focus=%.1f|hpw=%.1f" % [
		tag, float(ai.w_idle_hit_penalty), float(ai.w_risk), float(ai.w_risk_core_pow),
		float(ai.w_threat_dead_fold), float(ai.w_incoming_pool), float(ai.w_form_escape),
		float(ai.w_form_cohesion), float(ai.w_focus_fire), float(ai.w_hp_value)])
	print("PROBE|%s|unit|name=%s|cell=%s|hp=%d|eatk=%d|emove=%d|range=%d|miner=%s|dist=%d|engaged0=%s" % [
		tag, String(su.name), str(su.cell), int(su.hp), int(su.eatk), int(su.emove), int(su.atk_range),
		str(sim.units[miner].cell), int(ai.grid.distance(su.cell, sim.units[miner].cell)), str(sim.engaged0)])
	# ① 可达格 + 逐格"够得到几个"
	var reach: Dictionary = ai._move_cells(sim, su)
	var rows: Array = []
	for c in reach.keys():
		var cc: Vector2i = c
		rows.append({ "c": cc, "d": int(ai.grid.distance(cc, sim.units[miner].cell)),
			"n": ai._valid_targets(sim, su, cc).size() })
	rows.sort_custom(func(a, b): return int(a["d"]) < int(b["d"]))
	var reach_txt := ""
	for r in rows:
		reach_txt += "%s(d%d,n%d) " % [str(r["c"]), int(r["d"]), int(r["n"])]
	print("PROBE|%s|reach|n=%d|%s" % [tag, rows.size(), reach_txt])
	# ② 枚举"雪拳"的几条候选（其余两个单位保持原地不动），复刻 search() 的口径
	var alts: Array = [
		{ "tag": "A_打_3,2", "move": Vector2i(3, 2), "atk": miner },
		{ "tag": "B_打_2,3", "move": Vector2i(2, 3), "atk": miner },
		{ "tag": "C_走_3,0_不打", "move": Vector2i(3, 0), "atk": -1 },
		{ "tag": "D_原地_不打", "move": null, "atk": -1 },
	]
	var best_tag := ""
	var best_score := -1e18
	var base_sim = null      # D_原地_不打
	var attack_sim = null    # A_打_3,2
	for a in alts:
		var steps: Array = []
		for i in sim.units.size():
			if i == snow:
				steps.append({ "idx": i, "action": { "move": a["move"], "atk": int(a["atk"]) } })
			elif sim.units[i].fn == DataRegistry.Faction.ENEMY:
				steps.append({ "idx": i, "action": { "move": null, "atk": -1 } })
		var r := _score(ai, sim, steps)
		var s2 = r["sim"]
		var mu = s2.units[miner]
		var nu = s2.units[snow]
		print("PROBE|%s|alt|%s|score=%.2f|eval=%.2f|idle=%.2f|miner_hp=%d|snow_hp=%d" % [
			tag, String(a["tag"]), float(r["score"]), float(r["eval"]), float(r["idle"]),
			int(mu.hp), int(nu.hp)])
		if float(r["score"]) > best_score:
			best_score = float(r["score"])
			best_tag = String(a["tag"])
		if String(a["tag"]) == "D_原地_不打":
			base_sim = s2
		if String(a["tag"]) == "A_打_3,2":
			attack_sim = s2
	print("PROBE|%s|best_alt|%s|score=%.2f" % [tag, best_tag, best_score])
	_terms_diff(ai, tag + "_A vs D", base_sim, attack_sim)
	_terms_dump(ai, tag + "_D", base_sim)
	_terms_dump(ai, tag + "_A", attack_sim)
	# ③ 真跑一遍 search()，看它选了什么
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var ptxt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		ptxt += "%s[%s->%s,atk=%d] " % [String(sim.units[idx].name),
			str(sim.units[idx].cell), ("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	print("PROBE|%s|search|steps=%d|%s" % [tag, plan.size(), ptxt])

# ---------------------------------------------------------------- 案例2：红帽 / 雪拳 vs 复仇者
func _case2(nm: Dictionary) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(1, 2), 13, 5, 2, "红帽我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 1), 26, 2, 3, "雪拳我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_43", Vector2i(4, 1), 14, 1, 2, "风语者我"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_23", Vector2i(2, 2), 26, 2, 2, "复仇者敌"))
	var ai = _mk_ai(nm)
	var sim = _build(ai, descs)["sim"]
	var av := _find(sim, "复仇者敌")
	for nm2 in ["红帽我", "雪拳我", "风语者我"]:
		var i := _find(sim, nm2)
		var u = sim.units[i]
		print("PROBE|C2|unit|%s|cell=%s|hp=%d|eatk=%d|emove=%d|range=%d|dist_to_avenger=%d|targets=%d" % [
			nm2, str(u.cell), int(u.hp), int(u.eatk), int(u.emove), int(u.atk_range),
			int(ai.grid.distance(u.cell, sim.units[av].cell)), ai._valid_targets(sim, u, u.cell).size()])
	# 逐个单位枚举：打复仇者 vs 原地不打（其余两个保持原地）
	for nm2 in ["红帽我", "雪拳我"]:
		var i := _find(sim, nm2)
		var u = sim.units[i]
		if ai._valid_targets(sim, u, u.cell).size() == 0:
			print("PROBE|C2|alt|%s|no_target_in_place" % nm2)
			continue
		for mode in ["打", "不打"]:
			var steps: Array = []
			for j in sim.units.size():
				if j == i:
					var atkv := av if mode == "打" else -1
					steps.append({ "idx": j, "action": { "move": null, "atk": atkv } })
				elif sim.units[j].fn == DataRegistry.Faction.ENEMY:
					steps.append({ "idx": j, "action": { "move": null, "atk": -1 } })
			var r := _score(ai, sim, steps)
			var s2 = r["sim"]
			print("PROBE|C2|alt|%s_%s|score=%.2f|eval=%.2f|idle=%.2f|me_hp=%d|avenger_hp=%d" % [
				nm2, mode, float(r["score"]), float(r["eval"]), float(r["idle"]),
				int(s2.units[i].hp), int(s2.units[av].hp)])
			if mode == "打":
				var r0 := _score(ai, sim, _idle_steps(sim, i))
				_terms_diff(ai, "C2_" + nm2, r0["sim"], s2)
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var ptxt := ""
	for st in plan:
		var idx2 := int(st["idx"])
		var act2: Dictionary = st["action"]
		var mv2: Variant = act2.get("move")
		ptxt += "%s[%s->%s,atk=%d] " % [String(sim.units[idx2].name), str(sim.units[idx2].cell),
			("原地" if mv2 == null else str(mv2)), int(act2.get("atk", -1))]
	print("PROBE|C2|search|steps=%d|%s" % [plan.size(), ptxt])

# ---------------------------------------------------------------- 工具
func _idle_steps(sim, keep: int) -> Array:
	var steps: Array = []
	for j in sim.units.size():
		if j == keep or sim.units[j].fn == DataRegistry.Faction.ENEMY:
			steps.append({ "idx": j, "action": { "move": null, "atk": -1 } })
	return steps

## 复刻 `search()` 的候选评分口径：`_evaluate(终态, end_of_turn)` − 累计 `IDLE_HIT_PENALTY`
## ⚠️ 这里那条 idle 判据必须与 `search()` **逐字同源**：引擎 2026-09-22 把判据从"原位够得到"
##    改成了"候选表里有没有 `atk >= 0`"⇒ 本函数同步改成读 `_actions_for()`。
##    （第一次跑就踩到过：探针里留着旧判据 ⇒ 打出来的还是"改前"的数。）
func _score(ai, sim, steps: Array) -> Dictionary:
	var s2 = sim.clone()
	var idle := 0.0
	for st in steps:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		if ai.w_idle_hit_penalty != 0.0 and int(a.get("atk", -1)) < 0:
			var iu = s2.units[idx]
			if iu != null and iu.alive and not iu.attacked and _any_attack(ai, s2, idx):
				idle += float(ai.w_idle_hit_penalty)
		ai._apply(s2, idx, a)
	var ev := float(ai._evaluate(s2, true))
	return { "sim": s2, "eval": ev, "idle": idle, "score": ev - idle }

## 与 `search()` 同源：本回合有没有"能打到人"的出招（原位打 / 走一步再打都算）。
func _any_attack(ai, sim, idx: int) -> bool:
	for a in ai._actions_for(sim, idx):
		if int(a.get("atk", -1)) >= 0:
			return true
	return false

func _terms_diff(ai, tag: String, base, other) -> void:
	if base == null or other == null:
		return
	var b: Dictionary = ai._eval_breakdown(base, true)
	var o: Dictionary = ai._eval_breakdown(other, true)
	var txt := ""
	for k in o.keys():
		var d := float(o[k]) - float(b.get(k, 0.0))
		if absf(d) > 0.005:
			txt += "%s%+.2f " % [String(k), d]
	if txt == "":
		txt = "无差异"
	print("PROBE|%s|terms|%s" % [tag, txt])

## 把某一侧的逐项绝对值打出来（只打非 0 的），用于看清"钱花在哪"
func _terms_dump(ai, tag: String, sim) -> void:
	if sim == null:
		return
	var d: Dictionary = ai._eval_breakdown(sim, true)
	var txt := ""
	for k in d.keys():
		if absf(float(d[k])) > 0.005:
			txt += "%s%.2f " % [String(k), float(d[k])]
	print("PROBE|%s|dump|%s" % [tag, txt])

func _mk_ai(nm: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 20000   # ⚠️ 不用 0：那份"不限时"的口径有已知死循环隐患（见 1_通用策略 §1.3）
	ai.set_weights(nm)
	return ai

func _build(ai, descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	return { "sim": sim }

func _desc(fn: int, hid: String, cell: Vector2i, hp: int, atk: int, emove: int, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var d := {
		"fn": fn, "hero": hid, "cell": cell, "hp": hp, "max_hp": maxi(int(hd.max_hp), hp),
		"atk": atk, "eatk": atk, "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}
	if hid == "hero_42":
		d["can_pickup_gold"] = true
	return d

func _find(sim, nm: String) -> int:
	for i in sim.units.size():
		if String(sim.units[i].name) == nm:
			return i
	return -1

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
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	var c := FileAccess.get_file_as_bytes(path)
	f.close()
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
