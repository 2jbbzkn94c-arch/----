extends Node
## 【2026-09-25 一次性探针·临时】宿魂（hero_46）**瞬移那一手被漏斗剪掉**的自检 ——
##   用户实机日志：「⚠️ 没选的那一手更值：从 (2,1) 走到 (3,6) 打 烛火（约 2 伤），选它本可多赚 4.9 分
##   ⇒ 疑似被搜索漏掉（剪枝）」，并说「宿魂经常被疑似剪枝」。
##
## 病灶假设：宿魂的落点 = **任意空格**（`_move_cells()` 里写死）⇒ 它的"瞬移到后排打人"要跟
##   "全员往前压"争阶段 1 的 `TWO_PHASE_LAYOUTS = 8` 个名额，排不进前 8 就永远进不了阶段 2。
## 本探针把那个盘面**手搓出来**，比较三臂：
##   `pl0` = 今天生产（`TWO_PHASE_LAYOUTS=8`, `TWO_PHASE_INNER=16`, `TWO_PHASE_POLISH=0`）
##   `pl1` = 同上 + **逐单位复查**（`TWO_PHASE_POLISH=1`）
##   `fd2` = 同上 + **漏斗同轮廓限席**（`FUNNEL_DIVERSITY=2`）
## 每臂打：宿魂这一手是否出手 / 打了谁 / 落到哪 / 终局完整分 / 思考毫秒。
## 用法：godot.exe --headless --path <根> --scene res://RL/probe/宿魂剪枝自检.tscn

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const ARMS := [
	["pl0（今天生产）", 0, 0],
	["pl1（+逐单位复查）", 1, 0],
	["fd2（+漏斗限席）", 0, 2],
]

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var nm := _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|weights=%s" % [_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS])
	for arm in ARMS:
		_arm(String(arm[0]), int(arm[1]), int(arm[2]), nm)
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, polish: int, diver: int, nm: Dictionary) -> void:
	# 盘面照用户那局的手搓版：我方（AI）三人挤在左上角，玩家在后排（烛火 15 血、近战）
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_46", Vector2i(2, 1), "宿魂"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_15", Vector2i(3, 1), "小阴影"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_48", Vector2i(1, 1), "装甲堡垒"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_17", Vector2i(2, 6), "烛火"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_18", Vector2i(1, 5), "长剑"))
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 30000
	ai.set_weights(nm)
	ai.set_weights({ "TWO_PHASE_LAYOUTS": 8, "TWO_PHASE_INNER": 16, "TWO_PHASE_POLISH": polish, "FUNNEL_DIVERSITY": diver })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var end = sim.clone()
	for st in plan:
		ai._apply(end, int(st["idx"]), st["action"])
	# 宿魂这一步
	var txt := ""
	var hero46 := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var who := String(sim.units[idx].hero_id)
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		var tn := "-" if atk < 0 else String(sim.units[atk].hero_id)
		txt += "%s[%s→%s,打%s] " % [who, "原地" if mv == null else str(mv), "出手" if atk >= 0 else "不出手", tn]
		if who == "hero_46":
			hero46 = "%s，%s，落点=%s，打=%s" % [
				"出手" if atk >= 0 else "**没出手**", "目标 " + tn if atk >= 0 else "无目标",
				"原地" if mv == null else str(mv), tn]
	print("PROBE|%s|思考%dms|计划=%s" % [tag, ms, txt])
	print("PROBE|%s|宿魂：%s｜终局完整分=%.2f" % [tag, hero46, float(ai._evaluate(end, true))])
	print("PROBE|%s|分账|阵型造=%d 送阶段2=%d｜阶段2 叶子=%d" % [
		tag, int(ai.last_tp_layouts_built), int(ai.last_tp_layouts_used), int(ai.last_tp_leaves)])

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
	return d if d is Dictionary else {}

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
