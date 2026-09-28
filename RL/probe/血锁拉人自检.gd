extends Node
## 【2026-09-28 一次性探针】用户报「血锁怎么不会拉人？只会贴着打」—— 要回答的是
##   **这是搜索问题还是定价问题**：AI 到底有没有把"站 2~3 格开钩"当成一个候选。
##
## 机制回顾（读代码得到的判据，探针就是来验它）：
##   · 血锁 hero_41 出生 `attack_range +2`（=3）、只能沿 6 条轴向直线攻击；`on_attack` 里
##     `Battle._pull_to()` 把目标拉到面前一格（**已贴身则不拉**）⇒ **拉人 = "从 2~3 格出手"的副作用**，
##     它不是一步可选动作。所以"会不会拉人"等价于"AI 会不会选距离 ≥2 的那条出手线"。
##   · 全引擎唯一能读到位移的地方是威胁估计 `_displace_landing_cells()`（L8433-8435）——那是**对手打我**；
##     我方自己拉人**没有任何评分项**（L1125 只有一行 `血锁钩爪开团` 注释，没有 `var`、没有读者）。
##
## 六个盘面（全部"血锁与目标在同一条轴上、中间留空"，否则拉人/直线都无从谈起）：
##   ① 独狼·距离3：能拉 vs 能走1格→贴身打 ‖ 末态分对照（预期：同分 ⇒ 搜索无理由选拉）
##   ② 独狼·距离4：只有"走1格到3格"才够得着拉（走2格到2格也行）‖ 看它选哪条
##   ③ 独狼·距离2：拉与贴身**同一回合都可达**（走1格贴身 / 原地开钩）‖ 最干净的 A/B
##   ④ 带队友：队友**只有拉完那一格够得到**目标 ⇒ 拉人开团该被看见吗
##   ⑤ 有第二个敌人：拉进来会让自己多挨一刀（自己给自己加权暴露）⇒ 反向推力有多大
##   ⑥ 噩梦档全队搜索：血锁+两队友 vs 三敌人，直接看 search() 给出的招
## 输出：每行 `LOCK|...`，末尾 `LOCK|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"
const MELEE := 0

var _grid: HexGrid
var _w: Dictionary = {}
var _logf: FileAccess = null

func _log(s: String) -> void:
	print(s)
	if _logf == null:
		_logf = FileAccess.open("res://.godot_userdata/_lock_probe.log", FileAccess.WRITE)
	if _logf != null:
		_logf.store_line(s)
		_logf.flush()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	_w = _load_flat_weights(NIGHTMARE_PATH)
	_log("LOCK|CFG|fork=%s|keys=%d|BEAM=%d|SEARCH_MODE=%d|ENGAGE_PULL_PER_CELL=%.2f|RISK_W=%.2f|MOVE_ACCEPT_DAMAGE=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), _w.size(), int(_w.get("BEAM", 0)), int(_w.get("SEARCH_MODE", 0)),
		float(_w.get("ENGAGE_PULL_PER_CELL", 0.0)), float(_w.get("RISK_W", 0.0)),
		int(_w.get("MOVE_ACCEPT_DAMAGE", 0))])
	_s1()
	_s2()
	_s3()
	_s4()
	_s5()
	_s6()
	_log("LOCK|END")
	get_tree().quit(0)

# ---------------- 盘面①：独狼 · 距离3 ----------------
func _s1() -> void:
	_log("LOCK|① 独狼·目标在3格外（同轴、(2,2)→(2,5)，中间两格空）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "①")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "①｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "①")

# ---------------- 盘面②：独狼 · 距离4 ----------------
func _s2() -> void:
	_log("LOCK|② 独狼·目标在4格外（(2,2)→(2,6)：走1格可开钩、走2格贴身）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 6), 24, 2, "巨剑(假想敌)"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "②")
	_run_search(sim, "②")

# ---------------- 盘面③：独狼 · 距离2（最干净的 A/B） ----------------
func _s3() -> void:
	_log("LOCK|③ 独狼·目标在2格外（(2,2)→(2,4)：走1格贴身 / 原地开钩，两者同回合都可达）")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 4), 24, 2, "巨剑(假想敌)"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "③")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 3), "③｜A 原地开钩(距2) vs B 走1格贴身打")
	_run_search(sim, "③")

# ---------------- 盘面④：带队友（队友只有"拉完那格"够得到） ----------------
func _s4() -> void:
	_log("LOCK|④ 带队友：血锁(2,2) 目标(2,5) 队友长剑(1,1)——目标在原位时队友够不到，拉一格后够得到")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
		_ally("hero_18", Vector2i(1, 1), 20, 3, "长剑(队友)"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "④")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "④｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "④")

# ---------------- 盘面⑤：有第二个敌人（拉进来 = 自己多挨一刀） ----------------
func _s5() -> void:
	_log("LOCK|⑤ 反向推力：血锁(2,2) 目标(2,5) 另有敌(3,3)在侧后——拉人会把血锁拖进它的射程圈")
	var descs := [
		_lock(Vector2i(2, 2)),
		_foe("hero_12", Vector2i(2, 5), 24, 2, "巨剑(假想敌)"),
		_foe("hero_07", Vector2i(3, 3), 14, 5, "影丸(旁观敌)"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "⑤")
	_cmp_end_states(sim, 0, 1, Vector2i(2, 4), "⑤｜A 原地开钩(距3) vs B 走1格贴身打")
	_run_search(sim, "⑤")

# ---------------- 盘面⑥：噩梦档全队搜索 ----------------
func _s6() -> void:
	_log("LOCK|⑥ 全队：血锁+长剑+风语者 vs 巨剑+影丸+火枪手（照用户实机阵容的味道摆）")
	var descs := [
		_lock(Vector2i(2, 1)),
		_ally("hero_18", Vector2i(0, 1), 20, 3, "长剑"),
		_ally("hero_43", Vector2i(1, 0), 14, 1, "风语者"),
		_foe("hero_12", Vector2i(3, 4), 24, 2, "巨剑"),
		_foe("hero_07", Vector2i(4, 2), 14, 5, "影丸"),
		_foe("hero_09", Vector2i(5, 3), 20, 4, "火枪手"),
	]
	var sim := _mk_sim(descs)
	_dump_candidates(sim, 0, "⑥")
	_run_search(sim, "⑥")

# ---------------- 通用工具 ----------------

## 枚举该单位**全部候选**并按 `_evaluate(末态)` 打分（这就是搜索看到的全部信息）。
func _dump_candidates(sim, idx: int, tag: String) -> void:
	var ai = _mk_ai(_w)
	var acts: Array = ai._actions_for(sim, idx)
	var base := float(ai._evaluate(sim, true))
	var rows: Array = []
	for a in acts:
		var s2 = sim.clone()
		ai._apply(s2, idx, a)
		var sc := float(ai._evaluate(s2, true)) - base
		rows.append({ "d": float(sc), "txt": _act_txt(sim, idx, a, s2) })
	rows.sort_custom(func(x, y): return float(x["d"]) > float(y["d"]))
	_log("LOCK|%s|候选 %d 条（按末态分降序；基准=不动末态 %.2f）" % [tag, acts.size(), base])
	for i in mini(8, rows.size()):
		_log("LOCK|%s|  %+.3f  %s" % [tag, float(rows[i]["d"]), String(rows[i]["txt"])])

## 直接对照两条具体走法的末态分 —— 这就是"定价问题还是搜索问题"的判决。
func _cmp_end_states(sim, idx: int, tgt: int, walk_cell: Vector2i, tag: String) -> void:
	var ai = _mk_ai(_w)
	var base := float(ai._evaluate(sim, true))
	# A：原地出手（距离 ≥2 ⇒ 触发拉人）
	var a_act := {"move": null, "atk": tgt}
	var sa = sim.clone()
	ai._apply(sa, idx, a_act)
	# B：走到贴身那一格再打（距离 1 ⇒ `_pull_to` 直接 return，不拉）
	var b_act := {"move": walk_cell, "atk": tgt}
	var sb = sim.clone()
	ai._apply(sb, idx, b_act)
	var d_a := float(ai._evaluate(sa, true)) - base
	var d_b := float(ai._evaluate(sb, true)) - base
	_log("LOCK|%s|A 原地开钩 Δ=%+.3f（拉完：目标@%s 血%d / 血锁@%s 血%d）" % [
		tag, d_a, str(sa.units[tgt].cell), int(sa.units[tgt].hp), str(sa.units[idx].cell), int(sa.units[idx].hp)])
	_log("LOCK|%s|B 贴身打   Δ=%+.3f（走完：目标@%s 血%d / 血锁@%s 血%d）" % [
		tag, d_b, str(sb.units[tgt].cell), int(sb.units[tgt].hp), str(sb.units[idx].cell), int(sb.units[idx].hp)])
	_log("LOCK|%s|⇒ **A − B = %+.3f**（0 = 末态同分 ⇒ 搜索结构上分不出"拉"与"贴着打"）" % [tag, d_a - d_b])
	var bd_a: Dictionary = ai._eval_breakdown(sa, true)
	var bd_b: Dictionary = ai._eval_breakdown(sb, true)
	_log("LOCK|%s|A 主要项：%s" % [tag, _top_terms(bd_a)])
	_log("LOCK|%s|B 主要项：%s" % [tag, _top_terms(bd_b)])

## 真跑一遍 `search()`：这是生产里真正会被执行的计划。
func _run_search(sim, tag: String) -> void:
	var ai = _mk_ai(_w)
	var path: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var bits: Array[String] = []
	var pulled := 0
	for st in path:
		var idx := int((st as Dictionary)["idx"])
		var a: Dictionary = (st as Dictionary)["action"]
		var atk := int(a.get("atk", -1))
		var what := "不出手"
		if atk >= 0 and atk < sim.units.size():
			var tgt: Vector2i = sim.units[atk].cell
			var from: Vector2i = sim.units[idx].cell if a.get("move") == null else a["move"]
			var d := _grid.distance(from, tgt)
			what = "打 %s（间距 %d）%s" % [str(sim.units[atk].name), d, "→拉人" if d >= 2 else "→贴身(不拉)"]
			if d >= 2:
				pulled += 1
		if a.get("move") != null:
			what = "走到 %s，%s" % [str(a["move"]), what]
		bits.append("%s：%s" % [str(sim.units[idx].name), what])
	_log("LOCK|%s|search() 计划（%d 步，其中\"从≥2格出手\"=%d）" % [tag, path.size(), pulled])
	for b in bits:
		_log("LOCK|%s|  %s" % [tag, b])

func _act_txt(sim, idx: int, a: Dictionary, post) -> String:
	var atk := int(a.get("atk", -1))
	var mv := "原地" if a.get("move") == null else ("走到 " + str(a["move"]))
	if atk == -1:
		return mv + "，不出手"
	if atk == -2:
		return mv + "，敲障碍 " + str(a.get("atk_obs", "?"))
	var from: Vector2i = sim.units[idx].cell if a.get("move") == null else a["move"]
	var d := _grid.distance(from, sim.units[atk].cell)
	var tail := "→拉人" if d >= 2 else "→贴身(不拉)"
	var landed := str(post.units[atk].cell) if post.units[atk] != null else "?"
	return "%s，打 %s（间距 %d %s，落点 %s）" % [mv, str(sim.units[atk].name), d, tail, landed]

func _top_terms(bd: Dictionary) -> String:
	var keys: Array = bd.keys()
	keys.sort_custom(func(a, b): return absf(float(bd[a])) > absf(float(bd[b])))
	var bits: Array[String] = []
	for k in mini(6, keys.size()):
		if absf(float(bd[k])) < 0.005:
			continue
		bits.append("%s %+.2f" % [String(k), float(bd[k])])
	return " · ".join(bits)

func _mk_sim(descs: Array):
	var ai = _mk_ai(_w)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	return ai.build_state(descs, occ, {}, {}, {}, {}, {})

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 4000
	ai.set_weights(inject)
	return ai

func _lock(cell: Vector2i) -> Dictionary:
	# 血锁：攻 2 / 24 血 / 移动 2 / 射程 3（出生 +2）/ 近战；"只能直线"由 hero_id 判据给出
	return _u(DataRegistry.Faction.ENEMY, "hero_41", cell, 24, 24, 2, 2, 3, MELEE, [], "血锁")

func _foe(hero: String, cell: Vector2i, hp: int, atk: int, nm: String) -> Dictionary:
	return _u(DataRegistry.Faction.PLAYER, hero, cell, hp, hp, atk, 2, 1, MELEE, [], nm)

func _ally(hero: String, cell: Vector2i, hp: int, atk: int, nm: String) -> Dictionary:
	return _u(DataRegistry.Faction.ENEMY, hero, cell, hp, hp, atk, 2, 1, MELEE, [], nm)

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

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
