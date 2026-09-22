extends Node
## 血量账自检探针 —— 【2026-09-22 新增】用户发现「③血量账 在决策块第一步就不是 0」之后的定性仪器。
##
## 背景：③血量账 = `Σ_单位 (hp0 − hp)`，而 `hp0` = **快照那一刻的血**（`build_state` 里 `u.hp0 = u.hp`）。
##   ⇒ 任何一次 `search()` 的**第一行**（replay 的第一步之前）③ 必须恒为 **0.00**。
##   用户控制台里看到 `③血量账 +37.00→+40.00` 出现在一个 3 步块的**第一行** ⇒ 只有两种可能：
##     ① `search()` **改写了它的输入 sim**（跨候选/跨回合污染 —— T14 那类隐藏状态依赖）；
##     ② 建局之后、进 search 之前，血被别的路径改过。
##
## 本探针把这件事直接量出来（不跑对局、固定种子可复现）：
##   A) 建完局面立刻：逐单位记 `(hp0, hp)`，并算 ③（期望 0.00）
##   B) 用**同一个 sim 对象**跑 `search(sim, ENEMY)`
##   C) 再读同一个 sim：逐单位 `(hp0, hp)` + ③（与 A 不等 ⇒ **search 改了输入**）
##   D) 顺带报「计划回放终态分」与「search 自己选中的分」的差（选自 `_print_decision` 同口径：
##      `chosen["score"]` 拿不到，这里用 `_evaluate(终态)` 与逐步 Δ 的累计对照代替）
##
## 运行：
##   godot --headless --path <项目> --scene res://RL/probe/血量账自检.tscn -- [N]
## 输出：HPC|CFG / HPC|POS / HPC|UNIT / HPC|SUM / HPC|END
##   ⚠️ 本脚本不写任何文件、不改游戏状态；只读 fork + 权重。

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 8
	_grid.height = 6
	_rng.seed = 20260922
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var n := int(ua[0]) if ua.size() > 0 else 12
	var nm := _load_json("res://RL/weights/噩梦.json")
	var positions := _rand_positions(n)
	print("HPC|CFG|n=%d|nm_keys=%d|fork=%s" % [positions.size(), nm.size(), _sha("res://RL/ai/AI_Battle.gd")])
	var bad := 0
	var bad_after := 0
	for pos in positions:
		var r := _one(pos, nm)
		if absf(float(r["acc_before"])) > 0.001:
			bad += 1
		if absf(float(r["acc_after"])) > 0.001:
			bad_after += 1
		print("HPC|POS|%s|acc_before=%+.2f|acc_after=%+.2f|changed_units=%d|hp_delta=%.0f|steps=%d|end_score=%.2f|start_score=%.2f" % [
			String(pos["name"]), float(r["acc_before"]), float(r["acc_after"]),
			int(r["changed_units"]), float(r["hp_delta"]), int(r["steps"]),
			float(r["end_score"]), float(r["start_score"])])
	print("HPC|SUM|positions=%d|acc_before_nonzero=%d|acc_after_nonzero=%d" % [positions.size(), bad, bad_after])
	print("HPC|END")
	get_tree().quit(0)

## 一个局面：建局 → 读 ③ → search → 再读 ③
func _one(pos: Dictionary, nm: Dictionary) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	# ⚠️ 故意打开：`_print_decision` 只在 log_decisions=true 时才跑，而它内部会
	#   **克隆一份 `end_sim` 并把整条计划走完**（为了算"走完后"的威胁数）。
	#   要复现用户看到的"决策块第一行 ③ 不是 0"，必须让这段真的执行。
	ai.log_decisions = true
	ai.time_budget_ms = 0
	ai.set_weights(nm)
	var sim = ai.build_state(pos["descs"], pos["occ"], pos["gold"], pos["graves"], pos["obs"], pos["bombs"], pos["buff"], -1, {}, {}, {})
	# A) 建完立刻
	var before := _hp_list(sim)
	var acc_before := _acc3(ai, sim)
	var start_score := float(ai._evaluate(sim))
	# B) 同一个 sim 对象跑 search
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	# C) 再读同一个 sim
	var after := _hp_list(sim)
	var acc_after := _acc3(ai, sim)
	var changed := 0
	var hp_delta := 0.0
	for i in mini(before.size(), after.size()):
		if String(before[i]["s"]) != String(after[i]["s"]):
			changed += 1
			hp_delta += float(after[i]["hp"]) - float(before[i]["hp"])
	# D) 回放计划 → 终态分
	var cur = sim.clone()
	for st in plan:
		var idx := int(st.get("idx", -1))
		if idx < 0 or idx >= cur.units.size() or not cur.units[idx].alive:
			continue
		ai._apply(cur, idx, st.get("action", {}))
	var end_score := float(ai._evaluate(cur))
	return { "acc_before": acc_before, "acc_after": acc_after, "changed_units": changed,
		"hp_delta": hp_delta, "steps": plan.size(), "end_score": end_score, "start_score": start_score }

func _acc3(ai, sim) -> float:
	var d: Dictionary = ai._eval_breakdown(sim)
	return float(d.get("③血量账", 0.0))

## 每个单位的 (阵营, 名字, hp0, hp, alive) —— 用一个字符串指纹一起比，省得逐个比字段
func _hp_list(sim) -> Array:
	var out: Array = []
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null:
			continue
		out.append({ "hp": float(u.hp), "s": "%s|%s|%.1f|%.1f|%s" % [str(u.fn), String(u.hero_id), float(u.hp0), float(u.hp), str(u.alive)] })
	return out

## 随机局面：3v3、随机英雄/站位/血量/状态/地形（沿用 敏感度.gd 的口径，种子固定 ⇒ 可复现）
func _rand_positions(n: int) -> Array:
	var ids: Array = []
	for hid in DataRegistry.heroes.keys():
		var hd0 = DataRegistry.heroes[hid]
		if hd0 != null and not hd0.is_summon:
			ids.append(String(hid))
	ids.sort()
	var cells: Array = _grid.all_cells()
	var out: Array = []
	var guard := 0
	while out.size() < n and guard < n * 60:
		guard += 1
		var descs: Array = []
		var used := {}
		for side in 2:
			var fn := DataRegistry.Faction.ENEMY if side == 0 else DataRegistry.Faction.PLAYER
			for k in 3:
				var hid: String = String(ids[_rng.randi() % ids.size()])
				var hd = DataRegistry.heroes[hid]
				if hd == null:
					continue
				var cand: Vector2i = cells[_rng.randi() % cells.size()]
				if used.has(cand):
					continue
				used[cand] = true
				var pct := 0.3 + _rng.randf() * 0.7
				var hp := maxi(int(round(float(hd.max_hp) * pct)), 1)
				var nmu := "%s%s#%d" % ["我" if side == 0 else "敌", String(hd.display_name), descs.size()]
				var extra := {}
				var r := _rng.randf()
				if r < 0.08:
					extra["stunned"] = true
				elif r < 0.16:
					extra["silenced"] = true
				elif r < 0.24:
					extra["shield"] = true
				var d := {
					"fn": fn, "hero": hid, "cell": cand, "hp": hp, "max_hp": maxi(int(hd.max_hp), 1),
					"atk": maxi(int(hd.atk), 1), "eatk": maxi(int(hd.atk), 1),
					"move": maxi(int(hd.move_range), 1), "emove": maxi(int(hd.move_range), 1),
					"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
					"skills": (hd.skills as Array).duplicate(), "name": nmu,
				}
				for kk in extra.keys():
					d[kk] = extra[kk]
				if hid == "hero_42":
					d["can_pickup_gold"] = true
				descs.append(d)
		var ne := 0
		var np := 0
		for d2 in descs:
			if int(d2["fn"]) == int(DataRegistry.Faction.ENEMY):
				ne += 1
			else:
				np += 1
		if ne < 2 or np < 2:
			continue
		var obs := {}
		var buff := {}
		var gold := {}
		var bombs := {}
		for c in cells:
			var rr := _rng.randf()
			if rr < 0.06:
				obs[c] = true
			elif rr < 0.10:
				buff[c] = ["atk", "move", "shield", "heal"][_rng.randi() % 4]
			elif rr < 0.12:
				gold[c] = true
			elif rr < 0.14:
				bombs[c] = true
		var occ := {}
		for i in descs.size():
			occ[descs[i]["cell"]] = i
		out.append({ "name": "P%02d" % out.size(), "descs": descs, "occ": occ, "gold": gold,
			"graves": {}, "obs": obs, "bombs": bombs, "buff": buff })
	return out

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "nofile"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
