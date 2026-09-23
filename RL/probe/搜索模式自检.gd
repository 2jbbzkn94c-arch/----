extends Node
## 【2026-09-23 一次性探针】搜索模式自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户的问题：「为什么考虑的多了却变弱了？以前的路径也会考虑到，如果以前强，那他还是会按以前的路径」。
## **为什么这个反驳在动作空间上成立、但在搜索上不一定成立**：模式 2 的候选**确实**包含模式 0 的那些"移动+攻击"
##   一步组合（阶段 2 对还没挪位的单位就是直接给 `_actions_for()` 全套），但两阶段的**预算切法不同**：
##     阶段 1 用 `_layout_score()`（= `_evaluate(sim, end_of_turn=true)` 的**位置/威胁/队形分** + 一笔
##     "这一格够得到人就记它 eatk"的粗潜力）给**整队阵型**排序，只留 `_beam()` 条；随后**再只取前
##     `TWO_PHASE_LAYOUTS(8)` 套**进阶段 2，而阶段 2 每套的内层宽度只有 `max(4, beam/8)`。
##   ⇒ 模式 0 里"打分最高"的那套方案，如果它的**走位阵型**在阶段 1 的位置分里排到第 9 名开外，
##     模式 2 **永远看不到它**（选项还在，但在被评分之前就被剪掉了）。
##
## 本探针在**同一个局面**上分别跑 `SEARCH_MODE = 0` 与 `= 2`，然后用**同一个完整评分** `_evaluate(sim, true)`
## 量两套计划走完之后的终局分（两模式都在"全队行动完"的末态评分 ⇒ 可比）：
##   · 若 `score0 > score2` ⇒ **模式 2 确实自己把更好的方案丢了**（不是"选项变少"，是剪枝）；
##   · 再把两套计划各自的**走位阵型**单独拆出来，打上 `_layout_score()`（阶段 1 用的那把尺子）：
##       若 `proxy(布局0) < proxy(布局2)` ⇒ 阶段 1 的**位置分**把更好的阵型判没了（病灶 = 阶段 1 的尺子）；
##       若 `proxy(布局0) > proxy(布局2)` ⇒ 阶段 1 没看错，是**阶段 2 / 8 套漏斗**把它丢了。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag smprobe -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/搜索模式自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000   # 单次搜索上限（>=0；探针里给足但不无限，避免 §1.3 那个"空动作表死循环"把探针挂住）

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_SEARCH_MODE=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SEARCH_MODE", 0)), SEARCH_CAP_MS])
	_case("D1_近战前排", ["hero_13", "hero_12", "hero_18"], ["hero_13", "hero_12", "hero_18"])
	_case("D2_远程多", ["hero_24", "hero_09", "hero_20"], ["hero_13", "hero_12", "hero_18"])
	_case("D4_堡垒古拉战锤", ["hero_48", "hero_14", "hero_25"], ["hero_13", "hero_09", "hero_11"])
	_case("D5_宿魂塔盾德鲁伊", ["hero_46", "hero_11", "hero_08"], ["hero_13", "hero_12", "hero_18"])
	print("PROBE|END")
	get_tree().quit(0)

## 一个局面：我方（ENEMY，探针指挥方）三人在 y=1，玩家三人在 y=5
func _case(tag: String, my_ids: Array, foe_ids: Array) -> void:
	var descs: Array = []
	var xs := [1, 2, 3]
	for i in my_ids.size():
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(my_ids[i]), Vector2i(xs[i], 1), "我%d" % i))
	for i in foe_ids.size():
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(foe_ids[i]), Vector2i(xs[i], 5), "敌%d" % i))
	var built := _build(descs)
	var ai = built["ai"]
	var root = built["sim"]
	var r0 := _arm(ai, root, 0)
	var r2 := _arm(ai, root, 2)
	print("PROBE|CASE|%s|score0=%.2f|score2=%.2f|gap(0-2)=%+.2f|steps0=%d|steps2=%d|ms0=%d|ms2=%d" % [
		tag, r0["score"], r2["score"], r0["score"] - r2["score"], r0["steps"], r2["steps"], r0["ms"], r2["ms"]])
	print("PROBE|LAY|%s|proxy0=%.2f|proxy2=%.2f|full0=%.2f|full2=%.2f|same_plan=%s" % [
		tag, r0["proxy"], r2["proxy"], r0["lay_full"], r2["lay_full"], str(r0["plan"] == r2["plan"])])
	print("PROBE|PLAN0|%s|%s" % [tag, r0["plan_txt"]])
	print("PROBE|PLAN2|%s|%s" % [tag, r2["plan_txt"]])

## 跑一个模式：返回终局完整分 / 走位阵型分 / 计划
func _arm(ai, root, mode: int) -> Dictionary:
	ai.set_weights({ "SEARCH_MODE": mode })
	var s = root.clone()
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	# ① 完整计划走完的终局分（与现役同一个尺子：都按"全队行动完"评）
	var end = root.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var score := float(ai._evaluate(end, true))
	# ② 只把两套计划的"走位部分"拆出来（攻击整段不执行）⇒ 就是阶段 1 看到的那套阵型
	var lay = root.clone()
	for st in plan:
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		if mv != null and Vector2i(mv) != root.units[int(st["idx"])].cell:
			ai._apply(lay, int(st["idx"]), { "move": mv, "atk": -1 })
	var proxy := float(ai._layout_score(lay))
	var lay_full := float(ai._evaluate(lay, true))
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act2: Dictionary = st["action"]
		var mv2: Variant = act2.get("move")
		txt += "%s[%s->%s,atk=%d] " % [String(root.units[idx].name), str(root.units[idx].cell),
			("原地" if mv2 == null else str(mv2)), int(act2.get("atk", -1))]
	return { "score": score, "ms": ms, "steps": plan.size(), "proxy": proxy,
		"lay_full": lay_full, "plan": plan, "plan_txt": txt }

# ---------------------------------------------------------------- 工具
func _build(descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = SEARCH_CAP_MS
	ai.set_weights(_nm)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
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
