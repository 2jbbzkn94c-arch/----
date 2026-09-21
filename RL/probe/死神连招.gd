extends Node
## 死神连招探针（**只读型决策探针**，只新增文件、不改任何既有文件）——量一件事：
##   **AI 手里有位移英雄时，会不会用它把目标"从队友身边挪开"，好让死神(hero_30)打出 2 倍伤害？**
##
## 背景（用户 2026-09-20）：「因为这个位移的问题，我怀疑 AI 有位移单位也没用好。我举个例子。
##   再算最高伤害的时候，死神是只算了纸面数据，还是会配合位移英雄，打出一波高伤呢」。
## 死神机制（`heroes/hero_30_嬉皮死神.gd`）：「攻击时，如果目标**没有与其他敌人相邻**，则造成 **2 倍伤害**」。
##   ⇒ 把目标从它队友身边挪开 = 把 1× 变成 2×。谁能挪？`hero_27` 暗域（攻击后与目标**互换**）。
##
## 已知的代码事实（探针要验证的是"行为"，不是这两条）：
##   · **模拟层算了**：`_sim_mult()` 里 `hero_30` + `_sim_isolated()` ⇒ ×2（口径与真实 `Battle._is_isolated` 一致）；
##     位移在 `_apply` 里也是真跑的（`_sim_swap_cells`）。搜索是**自由行动顺序** ⇒ "先换位、后斩"这条线能被生成。
##   · **纸面算子没算**：`_outgoing_threat_on()` / `_rule_a_gain()` 的 `dmg_max` / `_gold_kill_ready()` /
##     `pick_sub_cell()|pick_sub_hero()` 都只乘 `eatk`，**不含倍率技、不含位移组合**（其中只有替补收尾那条在生产生效）。
##
## 两个场景（每个都带反面对照，否则"没打出 2×"分不清是"不会配合"还是"根本不认 2×"）：
##   `S1抱团`  ：目标 A 与队友 B **相邻**（谁都孤立不了）⇒ 只能靠暗域把 A 换出来才拿得到 2×
##   `S2已孤立`：A **本来就孤立** ⇒ 2× 摆在眼前（两组都应该打出 2×，这是"倍率看得见"的底线验证）
##
## 两组队伍（同位置同数值，唯一差别 = X1 是不是 hero_27）：
##   `dark` = X1 是**暗域**（有位移）· `plain` = X1 是**同数值普通单位**（无位移）⇒ `dark` vs `plain` 是主对照
##
## 每个（场景 × 队伍 × 配置）除了打印计划，还重建**理想连招终局**（强制"暗域走到隔离位→攻击换位，死神再斩"）
## 并比较三样东西，用来区分"没找到"还是"算出来不划算"：
##   `S_chosen` = 它实际选的整回合终局评分 · `S_combo` = 我强制打出的连招终局评分 · `margin` = 第一与第二名分差
##   · `S_combo > S_chosen` ⇒ **搜索层没找到更好的线**（剪枝/顺序问题）
##   · `S_combo ≤ S_chosen` ⇒ **评分层认为连招不划算**（账算不对，或换位的代价被算得更高）
##
## 跑法：
##   godot --headless --path <项目> --scene res://RL/probe/死神连招.tscn -- [beam]
## 输出：`HX|…` 每行一条；末尾 `HX|SUM|…` 汇总；同时落盘 `RL/reports/死神连招_原始输出.txt`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NM_PATH := "res://RL/weights/噩梦.json"

## 配置：`base` = 只看评分层（关推演层/规则B，直接量"评分层认不认连招"）；
##       `prod` = 生产噩梦口径（推演层 32 + `MOVE_ACCEPT_DAMAGE=1`）。
const CONFIGS := [
	{ "name": "base", "rollout": 0, "mad": 0.0 },
	{ "name": "prod", "rollout": 32, "mad": 1.0 },
]

var _grid: HexGrid
var _nm: Dictionary = {}
var _lines: Array = []

func _ready() -> void:
	_line("HX|BOOT")
	_grid = HexGrid.new()
	_grid.width = 8
	_grid.height = 6
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var beam := int(ua[0]) if ua.size() > 0 else 200
	_nm = _load_json(NM_PATH)
	_line("HX|CFG|scenarios=%d|teams=%d|configs=%d|beam=%d|fork_sha=%s|nm_sha=%s" % [
		2, 2, CONFIGS.size(), beam, _sha("res://RL/ai/AI_Battle.gd"), _sha(NM_PATH)])
	for s in _scenarios():
		_line("HX|SCEN|%s|%s" % [String(s["name"]), String(s["note"])])
		_line("HX|SCEN|%s|MAP|%s" % [String(s["name"]), _map_text(s)])
		_line("HX|SCEN|%s|CHECK|adj_A_B=%s|A孤立=%s|暗域站位=%s|隔离位=%s|起点=%s|d(x1,st)=%d|ok=%s" % [
			String(s["name"]), str(s["adj_ab"]), str(s["a_iso"]), str(s["st_cell"]),
			str(s["st_iso"]), String(s["cells_note"]), int(s["d_x1_st"]),
			"YES" if bool(s["ok"]) else "NO"])
		for team in ["dark", "plain"]:
			for cfg in CONFIGS:
				var r := _one(s, team, cfg, beam)
				var tag := "HX|ROW|%s|%s|%s" % [String(s["name"]), team, String(cfg["name"])]
				_line("%s|steps=%d|换位=%s|A落点=%s|死神打=%s|倍率=%s|总伤害=%.1f|S_chosen=%.2f|S_combo=%.2f|margin=%.2f|可达隔离位=%d" % [
					tag, int(r["steps"]), String(r["swap"]), str(r["a_after_swap"]),
					String(r["x0_hits"]), str(r["best_mult"]), float(r["total_dmg"]),
					float(r["s_chosen"]), float(r["s_combo"]), float(r["margin"]),
					int(r["n_iso_stand"])])
				for ln in r["plan_lines"]:
					_line("%s|%s" % [tag, String(ln)])
				_line("%s|判读|%s" % [tag, String(r["verdict"])])
	_dump()
	_line("HX|END|lines=%d" % _lines.size())
	get_tree().quit()

# ------------------------------------------------------------------ 盘面

## 几何全部**运行时算**（不手写六边形方向，免得写错）：
##   A(4,3) 是受害目标；B = A 的某个邻格（抱团场景才有）；`st` = A 的另一个邻格，且**不挨着 B**
##   ⇒ 暗域站到 `st` 上打 A ⇒ 换位后 A 落到 `st` ⇒ A 与 B 不相邻 ⇒ **孤立** ⇒ 死神 2×。
## X1(暗域/普通) 起点：距 `st` 恰好 2 格（够得着、又必须走）· X0(死神) 起点：距 A 2 格（本回合能斩）。
func _scenarios() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var ML := int(DataRegistry.AttackType.MELEE)
	var a_cell := Vector2i(4, 3)
	var nb: Array = _grid.neighbors(a_cell)
	var b_cell: Vector2i = nb[0]                       # 队友 B（抱团场景用）
	# `st`：A 的邻格里**离 B 最远**的那个 ⇒ 换位后 A 必然不挨 B
	var st_cell: Vector2i = nb[1]
	var best_d := -1
	for c in nb:
		var cc: Vector2i = c
		if not _grid.in_bounds(cc) or cc == b_cell:
			continue
		var d := _grid.distance(cc, b_cell)
		if d > best_d:
			best_d = d
			st_cell = cc
	var defs := [
		{ "name": "S1抱团", "cluster": true,
			"note": "A 与队友 B 相邻 ⇒ 谁都不孤立 ⇒ **只有暗域把 A 换出来才拿得到 2×**（主实验）" },
		{ "name": "S2已孤立", "cluster": false,
			"note": "A 旁边没有队友（B 放到远处）⇒ 2× 摆在眼前（反面对照：倍率本身看不看得见）" },
	]
	var out: Array = []
	for d in defs:
		var descs: Array = []
		var b_use := b_cell if bool(d["cluster"]) else Vector2i(7, 5)
		# `used`：A/B 占的格 + **隔离位 `st` 也必须空着**（连招要站上去）⇒ 起点不能落在这些格上
		var used := { a_cell: true, b_use: true, st_cell: true }
		var x1_cell := _free_cell_near(st_cell, 2, used)   # 暗域/普通 起点（离隔离位 1~2 格）
		used[x1_cell] = true
		var x0_cell := _free_cell_near(a_cell, 2, used)    # 死神 起点（本回合够得到 A）
		used[x0_cell] = true
		descs.append(_u(E, "hero_30", x0_cell, 30, 30, 5, 2, 1, ML, [], "X0死神"))
		descs.append(_u(E, "hero_27", x1_cell, 30, 30, 4, 2, 1, ML, [], "X1位移"))
		descs.append(_u(P, "hero_26", a_cell, 30, 30, 4, 2, 1, ML, [], "A目标"))
		descs.append(_u(P, "hero_26", b_use, 30, 30, 4, 2, 1, ML, [], "B队友"))
		# 自校验
		var adj_ab := _grid.distance(a_cell, b_use) == 1
		var a_iso := _isolated_static(a_cell, b_use)
		var st_iso := _isolated_static(st_cell, b_use)
		var d_x1_st := _grid.distance(x1_cell, st_cell)
		out.append({
			"name": String(d["name"]), "note": String(d["note"]),
			"cluster": bool(d["cluster"]),
			"descs": descs, "occ": _occ(descs),
			"x0_idx": 0, "x1_idx": 1, "a_idx": 2, "b_idx": 3,
			"st_cell": st_cell, "a_cell": a_cell, "b_cell": b_use,
			"adj_ab": adj_ab, "a_iso": a_iso, "st_iso": st_iso,
			"d_x1_st": d_x1_st, "cells_note": "%s→%s" % [str(x1_cell), str(x0_cell)],
			# 有效条件：抱团场景 A **不**孤立且 `st` 孤立（否则连招无从谈起）；孤立场景 A 本就孤立
			"ok": (st_iso and ((a_iso == false) if bool(d["cluster"]) else a_iso) and d_x1_st <= 2),
		})
	return out

## 找一个"离 center 最近的一圈里、界内、没被别人占、也不在 `used` 里"的空格（几何用算的，不手写）
func _free_cell_near(center: Vector2i, r: int, used: Dictionary = {}) -> Vector2i:
	for ring in range(1, r + 2):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				var c := Vector2i(center.x + dx, center.y + dy)
				if not _grid.in_bounds(c) or used.has(c):
					continue
				if _grid.distance(c, center) == ring:
					return c
	return center

## 静态口径的"孤立"：1 格内没有同阵营队友（探针自己算一份，用来做盘面自校验；
## 运行时那半用 AI 自己的 `_sim_isolated()`，见 `_one`）
func _isolated_static(cell: Vector2i, other: Vector2i) -> bool:
	return _grid.distance(cell, other) != 1

# ------------------------------------------------------------------ 跑一个格子

func _one(s: Dictionary, team: String, cfg: Dictionary, beam: int) -> Dictionary:
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0                      # 可复现：不用墙钟兜底
	ai.set_weights(_build_weights(team, cfg, beam))
	var descs: Array = (s["descs"] as Array).duplicate(true)
	# 队伍变体：X1 是暗域还是同数值普通单位（只换 hero id，数值不变）
	if team == "plain":
		descs[1]["hero"] = "hero_26"
	var sim = ai.build_state(descs, _occ(descs))
	var x0 = sim.units[int(s["x0_idx"])]
	var x1 = sim.units[int(s["x1_idx"])]
	var a0 = sim.units[int(s["a_idx"])]
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)

	# --- 可行连招的存在性：暗域能不能站到"隔离位"上打 A（用引擎自己的落点集合函数） ---
	# ⚠️ 只有 hero_27 才有"换位"这个技能；普通单位（对照组）虽然有同样的可达站位，但换了也没意义
	#    ⇒ 对照组这里恒为 0，别被"它也能站过去"误导。
	var n_iso_stand := 0
	var st_hit: Vector2i = s["st_cell"]
	if x1.hero_id == "hero_27":
		for cell in ai._displace_standing_cells(sim, x1, a0):
			var cc: Vector2i = cell
			if _isolated_static(cc, Vector2i(s["b_cell"])):
				n_iso_stand += 1
				st_hit = cc

	# --- 走一遍它选出来的计划，逐步记录 ---
	var fin = sim
	var lines: Array = []
	var steps := 0
	var swap_done := false
	var a_cell_before_swap: Vector2i = a0.cell
	var a_after_swap: Vector2i = a0.cell
	var hits: Array = []
	var best_mult := 0
	var total_dmg := 0.0
	for st in plan:
		var idx := int(st.get("idx", -1))
		if idx < 0 or idx >= fin.units.size():
			continue
		var u = fin.units[idx]
		if u == null or not u.alive:
			continue
		var act: Dictionary = st.get("action", {})
		var mv = act.get("move", null)
		var tgt := int(act.get("atk", -99))
		var land: Vector2i = u.cell if mv == null else Vector2i(mv)
		var tname := "无"
		var hp_before := -1
		var iso_now := false
		var mul := 0
		if tgt >= 0 and tgt < fin.units.size():
			var tv = fin.units[tgt]
			tname = "%s#%d" % [String(tv.name), tgt]
			hp_before = int(tv.hp)
			if u.hero_id == "hero_30":
				iso_now = bool(ai._sim_isolated(fin, tv, u))
				mul = int(ai._sim_mult(fin, u, tv))
		# 暗域那一手：记下"换位前后的 A"
		if u.hero_id == "hero_27" and tgt == int(s["a_idx"]):
			a_cell_before_swap = fin.units[int(s["a_idx"])].cell
		var c = fin.clone()
		ai._apply(c, idx, act)
		var dmg := 0.0
		var cell_moved := ""
		if tgt >= 0 and tgt < c.units.size():
			var tv2 = c.units[tgt]
			dmg = float(maxi(hp_before - int(tv2.hp), 0))
			total_dmg += dmg
			cell_moved = str(fin.units[tgt].cell) + "→" + str(tv2.cell)
			if u.hero_id == "hero_30":
				hits.append("%s伤%.0f倍率%d孤立=%s" % [tname, dmg, mul, str(iso_now)])
				best_mult = maxi(best_mult, mul)
		if u.hero_id == "hero_27" and tgt == int(s["a_idx"]):
			swap_done = true
			a_after_swap = c.units[int(s["a_idx"])].cell
		lines.append("%s：移动%s→%s 打%s%s" % [String(u.name), str(u.cell), str(land),
			tname, ("（伤%.0f %s）" % [dmg, cell_moved]) if dmg > 0 else ""])
		fin = c
		steps += 1
	var s_chosen := float(ai._evaluate(fin))
	var margin := _margin(ai, sim, plan, s_chosen)

	# --- 强制打一遍"理想连招"：暗域走到隔离位 → 打 A（换位）→ 死神补刀 → 比分 ---
	var s_combo := _forced_combo_score(ai, s, team, st_hit)

	var verdict := ""
	if bool(s["cluster"]):
		if team == "plain":
			verdict = "对照：无位移英雄 ⇒ 本场景拿不到 2×（倍率上限 %d）" % best_mult
		elif swap_done and best_mult == 2:
			verdict = "✅ 会配合：先换位把 A 挪出队友身边，再让死神打 2×"
		elif swap_done:
			verdict = "⚠️ 换了位但**没用上** 2×（死神没打被换出去的那个/或顺序反了）"
		elif n_iso_stand > 0 and s_combo > s_chosen:
			verdict = "❌ 没配合，但**强制连招的评分更高**（S_combo %.2f > S_chosen %.2f）⇒ **搜索层没找到这条线**" % [s_combo, s_chosen]
		elif n_iso_stand > 0:
			verdict = "🔸 没配合，且连招评分也不更高（%.2f ≤ %.2f）⇒ **评分层认为不划算**（换位代价 > 2× 收益）" % [s_combo, s_chosen]
		else:
			verdict = "— 盘面上不存在隔离位（连招不可达）"
	else:
		verdict = ("✅ 摆在眼前的 2× 会打（倍率 %d）" % best_mult) if best_mult == 2 \
			else ("❌ **连摆在眼前的 2× 都不打**（倍率 %d）⇒ 问题在倍率本身没进决策" % best_mult)
	return {
		"steps": steps, "swap": "有" if swap_done else "无", "a_after_swap": a_after_swap,
		"x0_hits": ("；".join(hits) if hits.size() > 0 else "无"), "best_mult": best_mult,
		"total_dmg": total_dmg, "s_chosen": s_chosen, "s_combo": s_combo, "margin": margin,
		"n_iso_stand": n_iso_stand, "plan_lines": lines, "verdict": verdict,
	}

## 强制连招的终局评分：把"暗域站到隔离位打 A（换位）"与"死神补刀 A"两步都落账后评分。
## 若死神那一步够不到就只落暗域那一步（那说明连招本身不可行，评分自然也不该更高）。
func _forced_combo_score(ai, s: Dictionary, team: String, st_hit: Vector2i) -> float:
	var descs: Array = (s["descs"] as Array).duplicate(true)
	if team == "plain":
		descs[1]["hero"] = "hero_26"
	var sim = ai.build_state(descs, _occ(descs))
	if team != "dark":
		return float(ai._evaluate(sim))            # 普通单位没有换位 ⇒ 无从"强制"
	var x1 = sim.units[int(s["x1_idx"])]
	var x0 = sim.units[int(s["x0_idx"])]
	var a_idx := int(s["a_idx"])
	if not _grid.in_bounds(st_hit) or st_hit == sim.units[a_idx].cell:
		return float(ai._evaluate(sim))
	if not ai._valid_targets(sim, x1, st_hit).has(a_idx):
		return float(ai._evaluate(sim))
	var c = sim.clone()
	ai._apply(c, int(s["x1_idx"]), { "move": st_hit, "atk": a_idx })    # 换位那一步（真机制）
	# 死神补刀：找一个能打到 A 的落点（优先原地）
	var x0c = c.units[int(s["x0_idx"])]
	var a_cell: Vector2i = c.units[a_idx].cell
	if ai._valid_targets(c, x0c, x0c.cell).has(a_idx):
		ai._apply(c, int(s["x0_idx"]), { "move": null, "atk": a_idx })
	else:
		for cell in ai._move_cells(c, x0c).keys():
			var cc: Vector2i = cell
			if ai._valid_targets(c, x0c, cc).has(a_idx):
				ai._apply(c, int(s["x0_idx"]), { "move": (null if cc == x0c.cell else cc), "atk": a_idx })
				break
	return float(ai._evaluate(c))

## 它实际选的这条线，比"次优线"高出多少（= 这个决定有多笃定；margin≈0 说明评分分不出来）
func _margin(ai, sim, plan: Array, s_chosen: float) -> float:
	var best_alt := -INF
	var first = plan[0] if plan.size() > 0 else null
	if first == null:
		return 0.0
	var idx := int(first.get("idx", -1))
	if idx < 0:
		return 0.0
	for a in ai._actions_for(sim, idx):
		if a == first.get("action", {}):
			continue
		var c = sim.clone()
		ai._apply(c, idx, a)
		best_alt = maxf(best_alt, float(ai._evaluate(c)))
	if best_alt == -INF:
		return 0.0
	return absf(s_chosen - best_alt)

func _build_weights(team: String, cfg: Dictionary, beam: int) -> Dictionary:
	var w := { "BEAM": beam }
	for k in _nm.keys():
		if String(k).begins_with("_"):
			continue
		w[k] = _nm[k]
	var mad := float(cfg.get("mad", -1.0))
	w["MOVE_ACCEPT_DAMAGE"] = float(_nm.get("MOVE_ACCEPT_DAMAGE", 1.0)) if mad < 0.0 else mad
	var ro := int(cfg.get("rollout", 0))
	if ro <= 0:
		w["ROLLOUT_TOPK"] = 0
		w["ROLLOUT_MODE"] = 0
	else:
		w["ROLLOUT_TOPK"] = ro
		w["ROLLOUT_MODE"] = int(_nm.get("ROLLOUT_MODE", 1))
	if team == "plain":
		w["DISPLACE_THREAT_W"] = 0.0               # 本探针只问"进攻配合"，位移威胁那条（防守）不掺进来
	return w

# ------------------------------------------------------------------ 小工具

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int, mv: int,
		rng: int, typ: int, skills: Array, nm: String, extra: Dictionary = {}) -> Dictionary:
	var d := {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}
	for k in extra.keys():
		d[k] = extra[k]
	return d

func _occ(descs: Array) -> Dictionary:
	var o := {}
	for i in descs.size():
		o[descs[i]["cell"]] = i
	return o

func _map_text(s: Dictionary) -> String:
	var rows: Array = []
	for y in _grid.height:
		var row := "%d |" % y
		for x in _grid.width:
			var c := Vector2i(x, y)
			var ch := " . "
			for d in (s["descs"] as Array):
				if Vector2i(d["cell"]) == c:
					ch = " %s " % _short(d)
			if c == Vector2i(s["st_cell"]):
				ch = ch.substr(0, 1) + "s" + ch.substr(2)
			row += ch
		rows.append(row)
	var head := "  |"
	for x in _grid.width:
		head += " %d " % x
	rows.append(head)
	return " ‖ ".join(rows)

func _short(d: Dictionary) -> String:
	var nm := String(d.get("name", "?"))
	if nm.begins_with("X0"):
		return "X0"
	if nm.begins_with("X1"):
		return "X1"
	return nm.substr(0, 2)

func _line(t: String) -> void:
	print(t)
	_lines.append(t)

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_line("HX|WARN|读不到 %s ⇒ 噩梦基线为空" % path)
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		_line("HX|WARN|%s 解析失败" % path)
		return {}
	return parsed

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "nofile"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)

func _dump() -> void:
	var dir := "res://RL/reports"
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("res://RL/reports/死神连招_原始输出.txt", FileAccess.WRITE)
	if f == null:
		print("HX|WARN|落盘失败")
		return
	for ln in _lines:
		f.store_line(String(ln))
	f.close()
