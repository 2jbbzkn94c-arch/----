extends Node
## 【2026-09-26 一次性探针·临时】"为什么有沉默时 AI 还把红帽暴露出来" —— 复现用户那一局的盘面，
##   把**账本**摊开：她每个落点的「全额挨打合计 / 廉价解线 / 沉默者够不够得到」＋**末态完整分账**。
##
## 盘面（照用户截图 + 他的决策日志反推，合计 10 伤与日志逐字对上）：
##   我方(AI/红)：红帽(2,3) 13血 · 雪拳(2,2) 12血 · 影丸(1,1) 14血
##   玩家(蓝)：雪拳(1,3) 10血（<嘲讽>）· 影丸(3,5) 14血 · 沉默术士(2,6) 15血
##   ⇒ 红帽若停在 (2,3)：雪拳2（近战·不算廉价解）+ 沉默术士3（远程+沉默）+ 影丸5（远程）= 10 伤。
##
## 三臂：`w0`（红帽键全关 = 甲方案前的生产基线）· `sil3`（③=3.0）· `sil15`（③=1.5）。
## 每臂打印：她的落点/出手 + 末态那两条输入 + **完整分账里绝对值最大的 8 项**（这就是"为什么"）。
##
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|fork=%s" % _sha("res://RL/ai/AI_Battle.gd"))
	_arm("㉖=0（关）· 红帽键也全关 = 今天之前的生产基线", 0.0, 0.0)
	_arm("㉖=2.0（现役新项）· 红帽键全关", 0.0, 2.0)
	_arm("㉖=2.0 + ③=3.0（全套）", 3.0, 2.0)
	_arm("㉖=6.0 + ③=3.0（加大剂量对照）", 3.0, 6.0)
	# 【固定末态】不做搜索：直接评"她就站在起点 (2,3)（挨 10 伤）"那一刻 ⇒ 手核 ㉖ 的读数
	_fixed("固定末态：她站起点(2,3)（全额 10）", 0.0)
	_fixed("固定末态：她站起点(2,3)（全额 10）", 2.0)
	_fixed("固定末态：她站起点(2,3)（全额 10）", 6.0)
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, w_sil: float, w_exp: float = 2.0) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 3), "红帽", 13))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 2), "雪拳", 12))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_07", Vector2i(1, 1), "影丸", 14))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_26", Vector2i(1, 3), "雪拳(嘲)", 10))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_07", Vector2i(3, 5), "影丸", 14))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_34", Vector2i(2, 6), "沉默术士", 15))
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 30000
	# ⚠️ 必须先注入**生产权重**（`噩梦.json`）再覆盖 `hero_40` 段：
	#   否则 ⑦核心风险 / ⑤拉力 / ⑥规则B 这些基线项全是 0 ⇒ 账本看不出"为什么"。
	ai.set_weights(_load_json(WEIGHTS))
	ai.set_weights({ "EXPOSURE_TOTAL_W": w_exp })
	var w40 := {}
	if w_sil > 0.0:
		w40 = { "REDCAP_SILENCE_GUARD_W": w_sil, "REDCAP_HP_FLOOR_W": 1.0 }
	ai.set_weights({ "hero_40": w40 })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	# 起点：她原地时的两条输入
	var cap = sim.units[0]
	var sil = sim.units[5]
	var info0 := {}
	var inc0: float = ai._incoming_total_on(sim, cap, cap.cell, info0)
	var parts0: Array[String] = []
	for row in (info0.get("parts", []) as Array):
		parts0.append("%s=%.0f" % [String(row[0]), float(row[1])])
	var sil_reach: bool = ai._threat_can_hit(sim, sil, cap.cell, cap)
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var end = sim.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	var body := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		if String(sim.units[idx].hero_id) != "hero_40":
			continue
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		body = "落点=%s，%s" % ["原地" if mv == null else str(mv), "出手打 " + String(sim.units[atk].hero_id) if atk >= 0 else "不出手"]
	var ecap = end.units[0]
	var esil = end.units[5]
	var info1 := {}
	var inc1: float = ai._incoming_total_on(end, ecap, ecap.cell, info1)
	var parts1: Array[String] = []
	for row in (info1.get("parts", []) as Array):
		parts1.append("%s=%.0f" % [String(row[0]), float(row[1])])
	var reach1: bool = ai._threat_can_hit(end, esil, ecap.cell, ecap)
	print("PROBE|%s|起点(2,3)：全额=%.0f（%s）沉默者够得到=%s ｜**红帽 %s**" % [
		tag, inc0, "、".join(parts0), str(sil_reach), (body if body != "" else "（没动作）")])
	print("PROBE|%s|末态：她的血=%d 全额=%.0f（%s）沉默者够得到=%s ｜完整分=%.2f" % [
		tag, int(ecap.hp), inc1, ("、".join(parts1) if parts1.size() > 0 else "∅"), str(reach1),
		float(ai._evaluate(end, true))])
	# 分账：绝对值最大的 8 项（"为什么"就在这张表里）
	var bd: Dictionary = ai._eval_breakdown(end, true)
	var rows: Array = []
	for k in bd.keys():
		rows.append({ "k": String(k), "v": float(bd[k]) })
	rows.sort_custom(func(x, y): return absf(float(x["v"])) > absf(float(y["v"])))
	var txt: Array[String] = []
	for i in mini(8, rows.size()):
		txt.append("%s=%.2f" % [String(rows[i]["k"]), float(rows[i]["v"])])
	print("PROBE|%s|分账(前8)：%s" % [tag, " · ".join(txt)])

func _desc(fn: int, hid: String, cell: Vector2i, nm: String, hp: int) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": hp, "max_hp": int(hd.max_hp),
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
	return d if d is Dictionary else {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)

## 只评"她原地不动"这一个末态：打印 ㉖ / ⑦ / ③ 三项 + 她那格的挨打合计（手核用）
func _fixed(tag: String, w_exp: float) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(2, 3), "红帽", 13))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_26", Vector2i(2, 2), "雪拳", 12))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_07", Vector2i(1, 1), "影丸", 14))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_26", Vector2i(1, 3), "雪拳(嘲)", 10))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_07", Vector2i(3, 5), "影丸", 14))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_34", Vector2i(2, 6), "沉默术士", 15))
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_load_json(WEIGHTS))
	ai.set_weights({ "EXPOSURE_TOTAL_W": w_exp, "hero_40": { "REDCAP_SILENCE_GUARD_W": 3.0, "REDCAP_HP_FLOOR_W": 1.0 } })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var info := {}
	var inc: float = ai._incoming_total_on(sim, sim.units[0], sim.units[0].cell, info)
	var bd: Dictionary = ai._eval_breakdown(sim, true)
	print("PROBE|%s｜㉖=%.1f｜她挨=%.0f ⇒ ㉖行=%.2f ⑦行=%.2f ③沉默行=%.2f｜完整分=%.2f" % [
		tag, w_exp, inc, float(bd.get("㉖暴露总量", 0.0)), float(bd.get("⑦核心风险", 0.0)),
		float(bd.get("红帽·沉默风险", 0.0)), float(ai._evaluate(sim, true))])
