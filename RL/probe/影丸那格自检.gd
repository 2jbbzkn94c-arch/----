extends Node
## 【2026-09-26 一次性探针】影丸(1,2) 那格为什么记 0 伤 —— 逐条查「暗域从 (0,2) 打影丸」这条线。
## 用户实报：暗域站 (0,2) 够不到雪拳(1,3)、但能打到影丸(1,2)，而 AI 日志写「下回合在这一格挨不到打（0 伤）」。
## 本探针按 **五条判据逐条打印**：路网距离 / 移动预算（含风语者 +1）/ 视线 / 嘲讽门 / 最终 `_threat_can_hit`，
## 再把影丸周围 6 格全列一遍（暗域走得到吗 · 门挡不挡），直接指出是哪一条把这条线吃掉的。
## 盘面按截图 + 日志还原（第 2 回合）：影丸5/14 (1,2) · 红帽5/13 (0,3) · 雪拳2/26 (1,3)【嘲·疾·带盾】
##   暗域3/20 (0,6) · 嬉皮死神3/20 (2,6) · 风语者1/14 (4,6)；障碍 酒桶 (2,4)(2,5)。
## 用法：& 'C:\Users\79076\Desktop\godot.exe' --headless --path 'D:\Game creating\战旗' --scene res://RL/probe/影丸那格自检.tscn

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_07", Vector2i(1, 2), "影丸", { "hp": 14, "eatk": 5 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(0, 3), "红帽", { "hp": 13, "eatk": 5 }))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(1, 3), "雪拳", { "hp": 26, "shield": true }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_27", Vector2i(0, 6), "暗域", { "hp": 20, "eatk": 3 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_30", Vector2i(2, 6), "嬉皮死神", { "hp": 20, "eatk": 3 }))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_43", Vector2i(4, 6), "风语者", { "hp": 14 }))
	var obs := { Vector2i(2, 4): true, Vector2i(2, 5): true }
	var built := _build(descs, obs)
	var ai = built["ai"]
	var sim = built["sim"]
	var yy = sim.units[0]     # 影丸
	var ax = sim.units[2]     # 雪拳
	var ay = sim.units[3]     # 暗域
	var cell := Vector2i(0, 2)
	print("PROBE|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	print("PROBE|盘面|影丸@%s hp%d ｜ 雪拳@%s hp%d 盾=%s 嘲讽=%s ｜ 暗域@%s hp%d 攻=%d" % [
		str(yy.cell), int(yy.hp), str(ax.cell), int(ax.hp), str(bool(ax.shield)),
		str((ax.skills as Array).has(DataRegistry.Skill.TAUNT)), str(ay.cell), int(ay.hp), int(ay.eatk)])
	print("PROBE|几何|(0,2)→影丸=%d ｜ (0,2)→雪拳=%d" % [
		_grid.distance(cell, yy.cell), _grid.distance(cell, ax.cell)])
	print("PROBE|判据①路网|暗域→(0,2) walk_dist=%d" % ai.walk_dist(sim, ay.cell, cell))
	print("PROBE|判据②预算|暗域 移动预算(含风语+1)=%d 射程=%d ⇒ 够到上限=%d" % [
		ai._threat_emove_next(sim, ay), int(ay.atk_range),
		ai._threat_emove_next(sim, ay) + int(ay.atk_range)])
	print("PROBE|判据③视线|(0,2)→影丸 blocked=%s" % str(ai._sim_path_blocked(sim, cell, yy.cell, ay)))
	print("PROBE|判据④嘲讽门|_taunt_allows(暗域, 影丸, (0,2))=%s" % str(ai._taunt_allows(sim, ay, yy, cell)))
	print("PROBE|判据⑤最终|_threat_can_hit(暗域,(1,2),门开)=%s ｜ 门关=%s" % [
		str(ai._threat_can_hit(sim, ay, yy.cell, yy)), str(ai._threat_can_hit(sim, ay, yy.cell, null))])
	var o1: Dictionary = {}
	var t1: float = ai._incoming_total_on(sim, yy, yy.cell, o1)
	print("PROBE|挨打合计|影丸那格 total=%.1f n=%s parts=%s" % [t1, str(o1.get("n")), str(o1.get("parts"))])
	var o2: Dictionary = {}
	var t2: float = ai._incoming_total_on(sim, yy, yy.cell, o2, true)
	print("PROBE|挨打合计|关嘲讽门 total=%.1f parts=%s" % [t2, str(o2.get("parts"))])
	for x in 5:
		for y in 7:
			var n := Vector2i(x, y)
			if _grid.distance(n, yy.cell) != 1:
				continue
			var w: int = ai.walk_dist(sim, ay.cell, n)
			print("PROBE|影丸邻格|%s|暗域walk=%d 预算%d 走得到=%s|视线挡=%s|门=%s" % [
				str(n), w, ai._threat_emove_next(sim, ay), str(w <= ai._threat_emove_next(sim, ay)),
				str(ai._sim_path_blocked(sim, n, yy.cell, ay)), str(ai._taunt_allows(sim, ay, yy, n))])
	print("PROBE|END")
	get_tree().quit(0)

# ---------------------------------------------------------------- 工具（与既有探针同款）
func _build(descs: Array, obs: Dictionary = {}) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 20000
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
