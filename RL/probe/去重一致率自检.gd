extends Node
## 【2026-09-24 一次性探针】阶段 1「同末态去重」一致率自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答的问题：`TWO_PHASE_DEDUP = 1`（阶段 1 按模拟状态指纹去重）**到底改不改 AI 的出招**？
##
## 为什么需要这个探针（它比整局胜率批灵敏得多）：
##   去重的机制推论是「被丢掉的条目与留下的那条**末态完全相同** ⇒ `_layout_score` 必然同分
##   ⇒ 阶段 2 拿到的 top-16 一套都不变」。但那条推论有两个理论边界：
##     ① **同分并列**时保留哪一条由生成顺序决定（今天是不稳定排序任选一条）⇒ `path` 里
##        **步骤的先后**可能不同（末态相同、纯演出顺序）；
##     ② `_evaluate` 本身有 §五 T14 那个**共享缓存的顺序依赖**（同一局面两次评估可能不同分），
##        去重把这层噪声也一并去掉了 ⇒ 理论上可能换掉某个"靠缓存运气上位"的候选。
##   整局胜率批要跑 96 局才能分辨 ~5 分的差别；而"出招一致率"是这个改动**本该 100%** 的量，
##   一个局面就能看出来 ⇒ 先在 N 个局面上量一致率，再决定要不要信那批胜率。
##
## 每个局面跑两臂（`TWO_PHASE_DEDUP = 0 / 1`），各打印：
##   · `same_plan`  = 两次 `search()` 的计划（idx + 落点 + 目标）**逐字相同**（最严）
##   · `same_end`   = 两次计划的**末态指纹**相同（`_sim_digest()`）⇒ 末态相同、只是步骤顺序不同
##   · `dscore`     = 末态完整评分之差（`_evaluate(sim, true)`，0 = 质量没变）
##   · 去重账       = `last_tp_p1_evals` / `last_tp_p1_dups`（省了多少次完整 `_evaluate`）+ 两阶段耗时
##
## 判读：`same_end` 全 YES 且 `dscore` 全 0 ⇒ **纯省钱、不降水平**（`same_plan` 为 NO 的那些
##   只是步骤顺序变了，属于有意副作用）；若有 `dscore ≠ 0`，看它是正还是负 —— 正 = 去重反而更好。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag ddprobe -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/去重一致率自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000   # 单次搜索上限（给足但不无限，避免 §1.3 那个"空动作表死循环"把探针挂住）

var _grid: HexGrid
var _nm: Dictionary = {}
var _n := 0
var _same_plan := 0
var _same_end := 0
var _sum_abs_d := 0.0
var _d_min := 0.0
var _d_max := 0.0
var _evals0 := 0
var _evals1 := 0
var _dups1 := 0
var _ms0 := 0
var _ms1 := 0

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_TWO_PHASE_DEDUP=%s|nm_SEARCH_MODE=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("TWO_PHASE_DEDUP", -1)),
		str(_nm.get("SEARCH_MODE", -1)), SEARCH_CAP_MS])
	# 前 4 个与 `搜索模式自检.gd` 同一批阵容（便于横向对照）
	_case("D1_近战前排", ["hero_13", "hero_12", "hero_18"], ["hero_13", "hero_12", "hero_18"], {})
	_case("D2_远程多", ["hero_24", "hero_09", "hero_20"], ["hero_13", "hero_12", "hero_18"], {})
	_case("D4_堡垒古拉战锤", ["hero_48", "hero_14", "hero_25"], ["hero_13", "hero_09", "hero_11"], {})
	_case("D5_宿魂塔盾德鲁伊", ["hero_46", "hero_11", "hero_08"], ["hero_13", "hero_12", "hero_18"], {})
	# 下面两个是**专门放大 n! 冗余**的局面：
	#   · E1 死灵法师会召唤骷髅 ⇒ 单位数从 3 顶到 4~5 ⇒ 排列冗余 24~120 倍（去重收益最大）
	#   · E2 带一列障碍 ⇒ 落点被地形切开，去重的"同末态"判定要正确区分"绕路 vs 不绕路"
	_case("E1_召唤多", ["hero_33", "hero_43", "hero_06"], ["hero_13", "hero_24", "hero_11"], {})
	_case("E2_一列障碍", ["hero_03", "hero_13", "hero_42"], ["hero_24", "hero_09", "hero_48"],
		{ Vector2i(2, 3): true, Vector2i(2, 4): true })

	print("PROBE|SUM|n=%d|same_plan=%d/%d|same_end=%d/%d|dscore[min=%+.2f,max=%+.2f,sum_abs=%.2f]|evals[no_dedup=%d,dedup=%d,dups_dropped=%d,cut=%.0f%%]|ms[no_dedup=%d,dedup=%d]" % [
		_n, _same_plan, _n, _same_end, _n, _d_min, _d_max, _sum_abs_d,
		_evals0, _evals1, _dups1,
		(100.0 * float(_dups1) / float(maxi(_evals0, 1))), _ms0, _ms1])
	print("PROBE|VERDICT|%s" % _verdict())
	print("PROBE|END")
	get_tree().quit(0)

func _verdict() -> String:
	if _n == 0:
		return "no_case"
	if _same_end == _n and absf(_sum_abs_d) < 1.0e-6:
		if _same_plan == _n:
			return "IDENTICAL: 计划逐字相同 + 末态相同 + 分数相同 ⇒ 纯省钱"
		return "SAFE_ORDER_ONLY: 末态与分数全同，只有 %d/%d 例的步骤顺序变了（有意副作用）" % [_n - _same_plan, _n]
	if _same_end == _n:
		return "SAME_END_DIFF_SCORE: 末态同一套但分数不同（说明 %s）⇒ 去重顺手去掉了 T14 那个缓存顺序噪声" % ("去重后更高" if _d_min > 0.0 else ("去重后更低" if _d_max < 0.0 else "有正有负"))
	return "CHANGED: 有 %d/%d 例的末态真的变了 ⇒ 去重改了搜索内容，必须看 Δpts 的胜率批" % [_n - _same_end, _n]

func _case(tag: String, my_ids: Array, foe_ids: Array, obs: Dictionary) -> void:
	var descs: Array = []
	var xs := [1, 2, 3]
	for i in my_ids.size():
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(my_ids[i]), Vector2i(xs[i], 1), "我%d" % i))
	for i in foe_ids.size():
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(foe_ids[i]), Vector2i(xs[i], 5), "敌%d" % i))
	var built := _build(descs, obs)
	var ai = built["ai"]
	var root = built["sim"]
	var r0 := _arm(ai, root, 0)
	var r1 := _arm(ai, root, 1)
	_n += 1
	if r0["plan"] == r1["plan"]:
		_same_plan += 1
	var same_end: bool = String(r0["digest"]) == String(r1["digest"])
	if same_end:
		_same_end += 1
	var ds := float(r1["score"]) - float(r0["score"])
	_sum_abs_d += absf(ds)
	if _n == 1 or ds < _d_min:
		_d_min = ds
	if _n == 1 or ds > _d_max:
		_d_max = ds
	_evals0 += int(r0["evals"])
	_evals1 += int(r1["evals"])
	_dups1 += int(r1["dups"])
	_ms0 += int(r0["ms"])
	_ms1 += int(r1["ms"])
	print("PROBE|CASE|%s|same_plan=%s|same_end=%s|score0=%.2f|score1=%.2f|dscore=%+.2f|steps0=%d|steps1=%d|evals0=%d|evals1=%d|dups1=%d|ms0=%d|ms1=%d" % [
		tag, str(r0["plan"] == r1["plan"]), str(same_end),
		r0["score"], r1["score"], ds, r0["steps"], r1["steps"],
		r0["evals"], r1["evals"], r1["dups"], r0["ms"], r1["ms"]])
	if r0["plan"] != r1["plan"]:
		print("PROBE|PLAN0|%s|%s" % [tag, r0["plan_txt"]])
		print("PROBE|PLAN1|%s|%s" % [tag, r1["plan_txt"]])

## 跑一臂：`TWO_PHASE_DEDUP = dedup`，返回终局分 / 末态指纹 / 计划 / 去重账
func _arm(ai, root, dedup: int) -> Dictionary:
	ai.set_weights({ "TWO_PHASE_DEDUP": dedup })
	var s = root.clone()
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var end = root.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var score := float(ai._evaluate(end, true))
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		txt += "%s[%s->%s,atk=%d] " % [String(root.units[idx].name), str(root.units[idx].cell),
			("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	return {
		"score": score, "ms": ms, "steps": plan.size(), "plan": plan, "plan_txt": txt,
		"digest": ai._sim_digest(end),
		"evals": int(ai.last_tp_p1_evals), "dups": int(ai.last_tp_p1_dups),
	}

# ---------------------------------------------------------------- 工具
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = SEARCH_CAP_MS
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, obs, {}, {})
	return { "sim": sim, "ai": ai }

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

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
