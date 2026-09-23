extends Node
## 决策损失探针（**不跑对局**）——"英雄特化"的可规模化仪器。
##
## 为什么换掉手写场景（`英雄特化.gd` 那套）：手写场景 = 一个英雄一套，49 英雄 × 两条轴
##   （自己用得好 / 应对对面）根本铺不开。这里换成棋类引擎的做法：
##   **用"更强的搜索"当参照解，量"生产搜索"相对它丢了多少分**（centipawn loss 的思路）。
##   ⇒ 不需要人写"正确答案"；任意键、任意英雄、任意局面都能批量算。
##
## 量什么：同一起始局面下
##     `prod`  = 生产设置（beam 可调）选出的计划
##     `ref`   = 更强设置（更宽 beam + 推演层）选出的计划
##     `loss`  = `_evaluate(ref 终态) − _evaluate(prod 终态)`（AI 视角，≥0 表示生产更差）
##   再按「**我方有哪个英雄**」和「**对面有哪个英雄**」两个维度聚合 ⇒ 两张排行榜。
##
## 运行：
##   godot --headless --path <项目> --scene res://RL/probe/决策损失.tscn -- [N] [prodBeam] [refBeam]
##   缺省 N=12 prodBeam=200 refBeam=600（⚠️ 2026-09-22 晚：原来的第 4 个参数 refRollout 已随"真推演层"整段删除）
##
## 输出：LOSS|CFG / LOSS|POS / LOSS|OWN / LOSS|FOE / LOSS|END

const FORK := preload("res://RL/ai/AI_Battle.gd")

## 要对比的配置（键注入）。`nm` = 噩梦权重当底；`base` = 噩梦原样
const CFG_NM := "nm"

var _grid: HexGrid
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 8
	_grid.height = 6
	_rng.seed = 20260919
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var n := int(ua[0]) if ua.size() > 0 else 12
	var prod_beam := int(ua[1]) if ua.size() > 1 else 200
	var ref_beam := int(ua[2]) if ua.size() > 2 else 600
	var nm := _load_json("res://RL/weights/噩梦.json")
	var positions := _rand_positions(n, nm)
	print("LOSS|CFG|n=%d|prod_beam=%d|ref_beam=%d|nm_keys=%d|fork=%s" % [
		positions.size(), prod_beam, ref_beam, nm.size(), _sha("res://RL/ai/AI_Battle.gd")])
	var own := {}
	var foe := {}
	var losses: Array = []
	for pos in positions:
		var r := _one(pos, nm, prod_beam, ref_beam)
		losses.append(float(r["loss"]))
		print("LOSS|POS|%s|loss=%.2f|prod=%.2f|ref=%.2f|steps_prod=%d|steps_ref=%d|same=%s" % [
			String(pos["name"]), float(r["loss"]), float(r["prod_score"]), float(r["ref_score"]),
			int(r["prod_steps"]), int(r["ref_steps"]), str(r["same"])])
		# 按"我方英雄 / 对面英雄"分别累计（每个出现的英雄各记一次）
		for hid in pos["own_heroes"]:
			_acc(own, String(hid), float(r["loss"]))
		for hid in pos["foe_heroes"]:
			_acc(foe, String(hid), float(r["loss"]))
	var mean := 0.0
	for v in losses:
		mean += float(v)
	mean = mean / maxf(float(losses.size()), 1.0)
	print("LOSS|SUM|n=%d|mean_loss=%.3f" % [losses.size(), mean])
	_dump("OWN", own)
	_dump("FOE", foe)
	print("LOSS|END")
	get_tree().quit(0)

func _acc(d: Dictionary, k: String, v: float) -> void:
	if not d.has(k):
		d[k] = { "n": 0, "sum": 0.0 }
	var e: Dictionary = d[k]
	e["n"] = int(e["n"]) + 1
	e["sum"] = float(e["sum"]) + v

func _dump(tag: String, d: Dictionary) -> void:
	var rows: Array = []
	for k in d.keys():
		var e: Dictionary = d[k]
		rows.append({ "h": String(k), "n": int(e["n"]), "mean": float(e["sum"]) / maxf(float(e["n"]), 1.0) })
	rows.sort_custom(func(a, b): return float(a["mean"]) > float(b["mean"]))
	for r in rows:
		print("LOSS|%s|%s|n=%d|mean=%.3f" % [tag, String(r["h"]), int(r["n"]), float(r["mean"])])

## 一个局面：生产计划 vs 参照计划的终态分差
func _one(pos: Dictionary, nm: Dictionary, prod_beam: int, ref_beam: int) -> Dictionary:
	var prod := _plan(pos, nm, prod_beam)
	var ref := _plan(pos, nm, ref_beam)   # 【2026-09-22 晚】ref_roll（真推演层）已随该层删除
	var ps := String(prod["fp"])
	var rs := String(ref["fp"])
	return { "loss": float(ref["score"]) - float(prod["score"]),
		"prod_score": float(prod["score"]), "ref_score": float(ref["score"]),
		"prod_steps": int(prod["steps"]), "ref_steps": int(ref["steps"]),
		"same": (ps == rs) }

## 用一组设置跑 search，并把"计划执行完的终态分"作为该计划的价值（AI 视角）
func _plan(pos: Dictionary, nm: Dictionary, beam: int) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	var w := { "BEAM": beam }
	for k in nm.keys():
		w[k] = nm[k]
	# ⚠️ 2026-09-22 晚：原来这里按入参开「真推演层」（ROLLOUT_TOPK/MODE）—— 该层已整段删除。
	ai.set_weights(w)
	var sim = ai.build_state(pos["descs"], pos["occ"], pos["gold"], pos["graves"], pos["obs"], pos["bombs"], pos["buff"])
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	# 回放计划 → 终态分（用同一个 `_evaluate`，所以两边口径一致）
	# ⚠️ 不能写 `var cur: Sim = …`：`Sim` / `SimUnit` 都是 BattleAI 的**内部类**，而本探针加载的是 fork
	#   （`RL/ai/AI_Battle.gd`，没有 `class_name`）⇒ 解析阶段就报 `Could not find type "Sim"`、
	#   整个脚本不加载 ⇒ 没有 quit() ⇒ headless 永久挂住且一行输出都看不到（上一版踩过）。
	var cur = sim
	var parts: Array = []
	for st in plan:
		var idx := int(st.get("idx", -1))
		if idx < 0 or idx >= cur.units.size() or not cur.units[idx].alive:
			continue
		_apply_safe(ai, cur, idx, st.get("action", {}))
		parts.append("%d:%s:%d" % [idx, str(st.get("action", {}).get("move", null)), int(st.get("action", {}).get("atk", -99))])
	var sc := float(ai._evaluate(cur))
	parts.sort()
	return { "score": sc, "steps": plan.size(), "fp": ">".join(parts) }

## 回放要作用在克隆上（`_plan` 里对 `cur` 逐步替换）—— 形参不能标 `Sim`（内部类，见上）
func _apply_safe(ai, cur, idx: int, action: Dictionary) -> void:
	ai._apply(cur, idx, action)

## 随机局面：6 个单位（3v3）、随机英雄/站位/血量/状态/地形（种子固定 ⇒ 可复现）
## 直接沿用 `敏感度.gd::_rand_positions` 的口径，只多返回"这一局有哪几个英雄"。
func _rand_positions(n: int, _nm: Dictionary) -> Array:
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
		var own_h: Array = []
		var foe_h: Array = []
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
				if side == 0:
					own_h.append(hid)
				else:
					foe_h.append(hid)
		var ne := 0
		var np := 0
		for d in descs:
			if int(d["fn"]) == int(DataRegistry.Faction.ENEMY):
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
			"graves": {}, "obs": obs, "bombs": bombs, "buff": buff,
			"own_heroes": own_h, "foe_heroes": foe_h })
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
