extends Node
## 【2026-09-23 一次性探针】大场面耗时自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户的问题：「单位一多速度就很慢（有死灵法师时约 15 秒思考），而且操作也不到位」。
## 目的：量出「**单位数 × beam × 搜索模式**」对**耗时**与**计划质量**的影响曲线，
##   好据此决定"从几个单位开始要自动降级"以及降成什么。
##
## 盘面：AI 侧 = 死灵法师(hero_33) + N-1 个召唤物（尽量用真实召唤单位 id），玩家侧恒 3 人。
##   N 取 3 / 5 / 7（真实局里死灵法师+2 骷髅 = 5）。
## 每个组合量四件事：
##   ① `search()` 墙钟耗时（上限 `CAP_MS`，用来判断"是不是算不完被砍"）；
##   ② 计划步数（有几步动作）；
##   ③ 计划走完后的**完整评分** `_evaluate(·, true)`（同一个尺子 ⇒ 质量可比）；
##   ④ 是否顶到上限。
##
## ⚠️ 本探针**把 `time_budget_ms` 放宽到 60s**（生产是 25000）⇒ 量的是"自然完成要多久"，
##   而不是"被预算砍到多久"；真要看生产口径的截断效果，把 `CAP_MS` 改回 25000 再跑。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag bigN -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/大场面耗时自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const CAP_MS := 60000

var _grid: HexGrid
var _nm: Dictionary = {}
var _skel := "hero_13"

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	# 真实召唤单位 id（DataRegistry.summons 的键）
	for k in DataRegistry.summons.keys():
		_skel = String(k)
		break
	print("PROBE|CFG|fork=%s|骷髅id=%s|nm_SEARCH_MODE=%s|nm_BEAM=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), _skel, str(_nm.get("SEARCH_MODE", 0)),
		str(_nm.get("BEAM", 0)), CAP_MS])
	var cells: Array = [Vector2i(2, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(3, 1), Vector2i(4, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2)]
	for n in [3, 5, 7]:
		for beam in [400, 200]:
			_case(n, beam, 2, cells)
	for n in [3, 5, 7]:
		_case(n, 200, 0, cells)
	print("PROBE|END")
	get_tree().quit(0)

func _case(n: int, beam: int, mode: int, cells: Array) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_33", Vector2i(2, 1), "死灵法师"))
	var placed := 1
	for i in range(1, cells.size()):
		if placed >= n:
			break
		descs.append(_desc(DataRegistry.Faction.ENEMY, _skel, cells[i], "骷髅%d" % placed))
		placed += 1
	# 玩家恒 3 人（近战 + 远程 + 嘲讽，站位固定在下方）
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_13", Vector2i(1, 6), "独脚龟"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", Vector2i(3, 6), "火枪手"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_22", Vector2i(2, 6), "圣光"))
	var built := _build(descs, {})
	var ai = built["ai"]
	var sim = built["sim"]
	var w: Dictionary = _nm.duplicate(true)
	w["SEARCH_MODE"] = mode
	w["BEAM"] = beam
	ai.set_weights(w)
	ai.time_budget_ms = CAP_MS
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var post = sim.clone()
	for st in plan:
		ai._apply(post, int(st["idx"]), st["action"])
	var score := float(ai._evaluate(post, true))
	print("PROBE|N=%d beam=%d mode=%d|AI单位=%d|ms=%d|顶上限=%s|步数=%d|终局分=%.2f" % [
		n, beam, mode, n, ms, str(ms >= CAP_MS - 50), plan.size(), score])

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

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var use := hid
	if not DataRegistry.heroes.has(use):
		use = "hero_13"          # 召唤单位不在英雄表里时的兜底（只影响耗时口径，不影响结论）
	var hd = DataRegistry.heroes[use]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": use, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
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
