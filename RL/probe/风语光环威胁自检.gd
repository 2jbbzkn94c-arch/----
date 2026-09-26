extends Node
## 【2026-09-26 一次性探针·临时】用户报「阈值比较伤害还是没有计算风语者 +1 移动力」——
##   三臂：`在`（对方有未受控风语者）/ `哑`（风语者被沉默）/ `无`（场上没有风语者）。
##   盘面：红帽(2,6) ← 敌人长剑(2,2)。长剑 move2 + 射程1 = 3 ⇒ 离她 4 格，**差一格**；
##   风语者一给 +1 ⇒ 4 ⇒ 正好够得到。打印：长剑 emove / 光环加数 / 能打到吗 / 她那格挨打合计。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	_arm("① 对方有风语者（未被沉默）⇒ 长剑 +1 移动 ⇒ 应该够得到她", false, true)
	_arm("② 风语者被沉默（光环不发）⇒ 应该够不到", true, true)
	_arm("③ 场上没有风语者 ⇒ 应该够不到", false, false)
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, sil: bool, has_ws: bool) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 6), "红帽"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_39", Vector2i(2, 2), "猎颅者（攻3·移动2·无疾行）"))
	if has_ws:
		var ws := _desc(DataRegistry.Faction.PLAYER, "hero_43", Vector2i(0, 0), "风语者（离她 6 格 ⇒ 它自己打不到）")
		ws["silenced"] = sil
		descs.append(ws)
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var cap = sim.units[0]
	var foe = sim.units[1]
	var inc: float = ai._incoming_total_on(sim, cap, cap.cell)
	var can: bool = ai._threat_can_hit(sim, foe, cap.cell, cap)
	print("PROBE|%s|猎颅者 emove=%d 光环后=%d（差 %d）｜她站 %s 离它 %d 格 ⇒ 能打到=%s｜她那格挨打合计=%.0f" % [
		tag, int(foe.emove), int(ai._threat_emove_next(sim, foe)),
		int(ai._threat_emove_next(sim, foe)) - int(foe.emove),
		str(cap.cell), _grid.distance(foe.cell, cap.cell), str(can), inc])

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

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)