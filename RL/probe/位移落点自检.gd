extends Node
## 【2026-09-26 一次性探针·临时】**位移落点重算**自检 —— 用户原话：
##   「在计算阈值比较伤害的时候，确实没有考虑到敌人的位移效果，比如说，AI 会考虑到暗域的 3 点伤害，
##     但是考虑不到暗域和 AI 换位后，他会吃到其他更多的伤害」。
##
## 四个盘面，每个盘面一只位移者 + 一个**只有落点够得到她**的近战：
##   ① 暗域 hero_27（攻击后换位）② 血锁 hero_41（攻击后拉人）③ 长角 hero_32（攻击后撞飞）④ 超新星 hero_21（打她队友 ⇒ 她被推离）
## 每盘打印：**旧口径**（`no_displace=true`，= 今天之前的算法）· **新口径**（默认）· 落点列表 · 落点处的逐笔来源。
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
	# ① 暗域：她 (2,6)；暗域 (2,3)（move3+range1=4 ⇒ 够得到她）；长剑 (1,2) 只在落点 (2,3) 够得到
	_panel("① 暗域换位", [
		["ENEMY", "hero_40", Vector2i(2, 6), "红帽"],
		["PLAYER", "hero_27", Vector2i(2, 3), "暗域"],
		["PLAYER", "hero_18", Vector2i(1, 1), "长剑"]])
	# ② 血锁：她 (2,6)；血锁 (2,3)（同列直线、射程 1+2=3 ⇒ 够得到）；长剑 (1,2) 只在被拉到 (2,4) 后够得到
	_panel("② 血锁拉人", [
		["ENEMY", "hero_40", Vector2i(2, 6), "红帽"],
		["PLAYER", "hero_41", Vector2i(2, 3), "血锁"],
		["PLAYER", "hero_18", Vector2i(1, 1), "长剑"]])
	# ③ 长角：她 (2,5)；长角 (2,3)（撞飞 ⇒ 她落到 (2,6)）；长剑 (1,6) 只在 (2,6) 够得到
	_panel("③ 长角撞飞", [
		["ENEMY", "hero_40", Vector2i(2, 5), "红帽"],
		["PLAYER", "hero_32", Vector2i(2, 4), "长角"],
		["PLAYER", "hero_18", Vector2i(1, 1), "长剑"]])
	# ④ 超新星：她 (2,5) + 队友巨剑 (2,4)；超新星 (2,2) 打巨剑 ⇒ 她被推离 ⇒ 落点 (2,6)
	_panel("④ 超新星击退（打队友把她推走）", [
		["ENEMY", "hero_40", Vector2i(2, 5), "红帽"],
		["ENEMY", "hero_16", Vector2i(2, 4), "队友波盾"],
		["PLAYER", "hero_21", Vector2i(2, 2), "超新星"],
		["PLAYER", "hero_18", Vector2i(1, 6), "长剑"]])
	_panel("⑤ 暗域换位 ⇒ 嬉皮死神的孤立 ×2（打 6）", [
		["ENEMY", "hero_40", Vector2i(2, 6), "红帽"],
		["ENEMY", "hero_11", Vector2i(1, 6), "队友塔盾（贴着她 ⇒ 原地不孤立）"],
		["PLAYER", "hero_27", Vector2i(2, 3), "暗域（换位）"],
		["PLAYER", "hero_30", Vector2i(2, 4), "嬉皮死神（孤立 ×2）"]])
	print("PROBE|END")
	get_tree().quit(0)

func _panel(tag: String, rows: Array) -> void:
	var descs: Array = []
	for r in rows:
		var fn := DataRegistry.Faction.ENEMY if String(r[0]) == "ENEMY" else DataRegistry.Faction.PLAYER
		descs.append(_desc(fn, String(r[1]), r[2] as Vector2i, String(r[3])))
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var t = sim.units[0]
	var old_out := {}
	var old_v: float = ai._incoming_total_on(sim, t, t.cell, old_out, false, true)
	var new_out := {}
	var new_v: float = ai._incoming_total_on(sim, t, t.cell, new_out)
	var lands := ai._displace_landing_cells(sim, t, t.cell)
	var lt: Array[String] = []
	for c in lands:
		var o2 := {}
		var v2: float = ai._incoming_total_on(sim, t, c, o2, false, true)
		lt.append("%s=%.0f" % [str(c), v2])
	print("PROBE|%s|她站 %s｜旧口径=%.0f 新口径=%.0f｜落点=[%s]｜被位移=%s" % [
		tag, str(t.cell), old_v, new_v, "、".join(lt), str(new_out.get("displaced", false))])
	print("PROBE|%s|两端逐笔：%s ⇒ %s" % [tag, _fmt(old_out), _fmt(new_out)])

func _fmt(o: Dictionary) -> String:
	var bits: Array[String] = []
	for row in (o.get("parts", []) as Array):
		var r: Array = row
		bits.append("%s%.0f" % [String(r[0]), float(r[1])])
	return ("(" + "+".join(bits) + ")") if bits.size() > 0 else "∅"

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
