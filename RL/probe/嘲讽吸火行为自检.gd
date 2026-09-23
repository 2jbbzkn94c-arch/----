extends Node
## 【2026-09-24 一次性探针】㉕嘲讽吸火**行为**自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答用户当初的两句原话（胜率批量不出这个）：
##   ① 「装甲堡垒站在其他英雄的后面，**起不到嘲讽的作用**」；
##   ② 「堡垒**龟缩在角落**不往前」。
##
## `难度体检 -Mode taunt` 给的是配对 Δpts（赢不赢），本探针给的是**它到底有没有往前站、后排有没有真的少挨打**：
##   每个剂量（`TAUNT_SOAK_W` = 0 / 1.5 / 3 / 6）跑一次 `search()`，然后把计划落到终局局面上量四件事：
##     · `advance`      = 装甲堡垒相对自己起始格**朝玩家方向前压了几格**（本探针里 AI 在下、玩家在上 ⇒ +y）
##     · `fort_in`      = 堡垒**自己**下回合的挨打合计（该涨：它得替后排吃火）
##     · `ally_in`      = **后排非嘲讽单位**下回合挨打合计（该降）
##     · `ally_in_free` = 同一批后排单位**把嘲讽门关掉**重算的挨打合计（`ignore_taunt=true`）
##                        ⇒ `ally_in_free − ally_in` 就是**嘲讽真正挡下来的那部分**（= ㉕ 的原始量）
##   另打印 `_taunt_soak(终局)` 与仓位/计划文本，便于和日志里的 `㉕嘲讽吸火 +X.XX` 对上。
##
## 判读：剂量越大 → `advance` ↑、`ally_in` ↓、`ally_in_free − ally_in` ↑ ⇒ **嘲讽在起作用**；
##   若四个剂量的 `advance` 全是 0 / `ally_in` 不动 ⇒ 这一项没把堡垒推到前面（就是用户报的那个病）。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag tauntbeh -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/嘲讽吸火行为自检.tscn')
## 输出：每行 `PROBE|...`（ASCII，只有名字是中文），末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000
const ARMS := [0.0, 1.5, 3.0, 6.0]   # 0 = 关（只有 ⑭判据修正）· 3.0 = 现役

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_TAUNT_SOAK_W=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("TAUNT_SOAK_W", -1)), SEARCH_CAP_MS])
	# P1：堡垒在**后排中间**（用户①）—— 三只都在 y=1，玩家在 y=3 一排
	_case("P1_堡垒在后排", [
		["hero_48", Vector2i(2, 1), "堡垒"],
		["hero_17", Vector2i(0, 1), "烛火"],
		["hero_43", Vector2i(4, 1), "风语者"],
	], [
		["hero_03", Vector2i(1, 3), "毒蛇"],
		["hero_13", Vector2i(2, 3), "红帽"],
		["hero_12", Vector2i(3, 3), "巨剑"],
	])
	# P2：堡垒**缩在角落**（用户②）—— 堡垒留在 (0,0) 角，后排两人在中间
	_case("P2_堡垒缩角落", [
		["hero_48", Vector2i(0, 1), "堡垒"],
		["hero_17", Vector2i(2, 1), "烛火"],
		["hero_43", Vector2i(3, 1), "风语者"],
	], [
		["hero_03", Vector2i(1, 3), "毒蛇"],
		["hero_13", Vector2i(2, 3), "红帽"],
		["hero_12", Vector2i(3, 3), "巨剑"],
	])
	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, my_rows: Array, foe_rows: Array) -> void:
	var descs: Array = []
	var fort_idx := 0
	for i in my_rows.size():
		descs.append(_desc(DataRegistry.Faction.ENEMY, String(my_rows[i][0]), Vector2i(my_rows[i][1]), String(my_rows[i][2])))
		if String(my_rows[i][0]) == "hero_48":
			fort_idx = i
	for i in foe_rows.size():
		descs.append(_desc(DataRegistry.Faction.PLAYER, String(foe_rows[i][0]), Vector2i(foe_rows[i][1]), String(foe_rows[i][2])))
	var built := _build(descs)
	var ai = built["ai"]
	var root = built["sim"]
	var fort_before: Vector2i = root.units[fort_idx].cell
	for w in ARMS:
		ai.set_weights({ "TAUNT_SOAK_W": float(w) })
		var s = root.clone()
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var end = root.clone()
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		var fort = end.units[fort_idx]   # ⚠️ 不写 `: SimUnit` —— 那是 fork 的**内部类**，探针作用域里没有这个类型名
		# 前压格数：AI 在下、玩家在上 ⇒ +y 就是往前。用"到最近玩家的格距"减少量更稳（不受朝向假设影响）。
		var d_before := _nearest_foe_dist(root, fort_before)
		var d_after := _nearest_foe_dist(end, fort.cell)
		var fort_in := float(ai._incoming_total_on(end, fort, fort.cell))
		var ally_in := 0.0
		var ally_free := 0.0
		var n_ally := 0
		for i in end.units.size():
			var u = end.units[i]
			if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
				continue
			if u.skills.has(DataRegistry.Skill.TAUNT):
				continue
			n_ally += 1
			ally_in += float(ai._incoming_total_on(end, u, u.cell))
			ally_free += float(ai._incoming_total_on(end, u, u.cell, {}, true))
		var soak := float(ai._taunt_soak(end))
		print("PROBE|ARM|%s|w=%.1f|fort=%s->%s|dist_to_foe=%d->%d|advance=%+d|fort_in=%.1f|ally_in=%.1f|ally_free=%.1f|blocked=%.1f|n_ally=%d|soak=%.2f|steps=%d|ms=%d" % [
			tag, float(w), str(fort_before), str(fort.cell), d_before, d_after, d_before - d_after,
			fort_in, ally_in, ally_free, ally_free - ally_in, n_ally, soak, plan.size(), ms])
		print("PROBE|PLAN|%s|w=%.1f|%s" % [tag, float(w), _plan_txt(ai, root, plan)])

func _nearest_foe_dist(sim, from: Vector2i) -> int:
	var best := 999
	for u in sim.units:
		if u == null or not u.alive or u.fn == DataRegistry.Faction.ENEMY:
			continue
		best = mini(best, _grid.distance(from, u.cell))
	return best

func _plan_txt(ai, root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		txt += "%s[->%s,atk=%d] " % [String(root.units[idx].name),
			("原地" if mv == null else str(mv)), int(act.get("atk", -1))]
	return txt

# ---------------------------------------------------------------- 工具（与其它探针同款）
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
