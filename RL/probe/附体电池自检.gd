extends Node
## 【2026-09-25 一次性探针·临时】⑬b「**附体电池**」（键 `POSSESS_BATTERY_W`）自检 ——
##   用户口径：宿魂附体到对面核心 ⇒ 站到火线上挨打就是白赚镜像；**但被沉默时不给价**（该走位走位）。
##
## 三臂 + 一手工对照：
##   `w0`  键 = 0（关）⇒ 应为 0
##   `w1`  键 = 1（开，= 本档 `hero_46` 段的值）⇒ 应为 `min(挨打合计, 目标剩余血) × 身价/20`
##   `w1s` 键 = 1 **且宿魂被沉默** ⇒ 应为 0（用户点名的那道门）
##   另打：挨打合计、目标剩余血、目标身价 —— 便于手核公式。
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
	var nm := _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|权重=%s" % [_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS])
	print("PROBE|CFG|噩梦档 hero_46 段 = %s" % str(nm.get("hero_46", {})))
	_arm("段里=0（关）", 0.0, false, nm)
	_arm("段里=1（开·本档现役）", 1.0, false, nm)
	_arm("段里=1（开）+ 宿魂被沉默", 1.0, true, nm)
	print("PROBE|END")
	get_tree().quit(0)

func _arm(tag: String, w: float, silenced: bool, nm: Dictionary) -> void:
	var descs: Array = []
	# 我方：宿魂（它今天已经把敌人核心附体了 —— 用 `poss_by` 直接摆出来）
	var soul := _desc(DataRegistry.Faction.ENEMY, "hero_46", Vector2i(2, 4), "宿魂")
	soul["silenced"] = silenced
	descs.append(soul)
	# 敌方：核心（共鸣者，被附体）+ 三个能打到宿魂的人
	var core := _desc(DataRegistry.Faction.PLAYER, "hero_47", Vector2i(2, 3), "共鸣者(核心)")
	core["poss_by"] = 0        # 被 0 号（宿魂）附体
	descs.append(core)
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_18", Vector2i(1, 4), "长剑"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_10", Vector2i(3, 2), "白游侠"))
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_14", Vector2i(3, 4), "大骑士"))
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(nm)
	# ⚠️ 必须往 **hero_46 段**里注入：真实读取走 `_wh(宿魂, "POSSESS_BATTERY_W", 扁平兜底)`，段里有值就用段里的 ⇒
	#    扁平注入会被本档 `hero_46` 段里的 1.0 盖住（第一版探针踩过这个坑，读数全 = 1.0 那一档）。
	ai.set_weights({ "hero_46": { "POSSESS_BATTERY_W": w } })
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var u = sim.units[0]                            # 宿魂
	var t = sim.units[1]                            # 被附体的核心
	var inc: float = ai._incoming_total_on(sim, u, u.cell)
	var val: float = ai._unit_value(sim, t)
	var expect := w * minf(inc, float(t.hp)) * val / 20.0
	var bd: Dictionary = ai._eval_breakdown(sim)
	var got := float(bd.get("⑬b附体电池", 0.0))
	print("PROBE|%s|挨打合计=%.1f｜目标剩余血=%d｜目标身价=%.2f ⇒ 期望=%.2f｜实测 ⑬b=%.2f｜完整分=%.2f" % [
		tag, inc, int(t.hp), val, expect, got, float(ai._evaluate(sim, true))])

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
