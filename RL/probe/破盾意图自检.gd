extends Node
## 【2026-09-24 一次性探针】㉔破盾的**意图**自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答 §五 T20 要的那个读数：「**poke 拆盾出现率**」——`SHIELD_BREAK_W` 从 0 加到 8，
##   AI 会不会真的改用"低伤那一下"去拆对面的盾（而不是照旧去打没盾的那个、把输出打满）。
##
## 口径（`_sim_take_damage` 里那笔）：`价值 = SHIELD_BREAK_W × SHIELD_BREAK_DMG_REF(1.0) / max(这一击伤害, 1.0)`
##   ⇒ **伤害越低越值**：1 伤拆盾 = 满价、5 伤拆盾 = 1/5。所以本探针刻意给 AI 配**一轻一重**两只：
##     轻 = 风语者(hero_43，攻 1) · 重 = 血锁(hero_40，攻 5)；对面两只：塔盾(hero_11，**带盾**) + 火枪手(hero_09，没盾)。
##   若 ㉔ 有用：`SHIELD_BREAK_W` ↑ ⇒ **轻的那只改去打带盾的**、`shield_break_val` ↑。
##
## 每臂（0 / 2 / 4 / 8）跑一次 `search()`，落到终局后量：
##   · `break_val`   = 终局 `sim.shield_break_val`（㉔ 在推演里累加的实际金额）
##   · `bd24`        = `_eval_breakdown(终局, true)["㉔破盾"]`（与上一条同口径的交叉验证）
##   · `shield_up`   = 带盾那只的盾**还在不在**
##   · `poke_hit_shield` = **轻的那只**这一回合有没有去打带盾的（= "poke 拆盾"的直接证据）
##   · `heavy_hit`   = 重的那只打了谁
##   · `score`       = 终局完整评分
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag shieldbeh -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/破盾意图自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"
const SEARCH_CAP_MS := 30000
const ARMS := [0.0, 2.0, 4.0, 8.0]   # 4.0 = 现役

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|nm_SHIELD_BREAK_W=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), str(_nm.get("SHIELD_BREAK_W", -1)), SEARCH_CAP_MS])
	# P1：轻(AI#0)与重(AI#1)都能同时够到两只；带盾那只血厚、没盾那只血薄 ⇒ 看它往哪儿打
	_case("P1_轻重都能打到两只", Vector2i(1, 3), Vector2i(3, 3))
	# P2：带盾那只**离得近**、没盾那只远一格 ⇒ 低伤拆盾的诱惑更大
	_case("P2_带盾的更近", Vector2i(1, 3), Vector2i(4, 4))
	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, shield_cell: Vector2i, plain_cell: Vector2i) -> void:
	var descs: Array = []
	# AI：0 = 轻（风语者 攻1）· 1 = 重（血锁 攻5）
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_43", Vector2i(1, 1), "轻我"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_40", Vector2i(3, 1), "重我"))
	# 玩家：0 = 带盾（塔盾）· 1 = 没盾（火枪手）
	var sh := _desc(DataRegistry.Faction.PLAYER, "hero_11", shield_cell, "盾敌")
	sh["shield"] = true
	descs.append(sh)
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", plain_cell, "无盾敌"))
	var built := _build(descs)
	var ai = built["ai"]
	var root = built["sim"]
	print("PROBE|POS|%s|eatk[轻=%d,重=%d]|shield_at=%s|plain_at=%s" % [
		tag, int(root.units[0].eatk), int(root.units[1].eatk), str(shield_cell), str(plain_cell)])
	for w in ARMS:
		ai.set_weights({ "SHIELD_BREAK_W": float(w) })
		var s = root.clone()
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var end = root.clone()
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		var bd: Dictionary = ai._eval_breakdown(end, true)
		var bd24 := float(bd.get("㉔破盾", 0.0))
		var shield_up := bool(end.units[2].shield)
		var poke_target := -1
		var heavy_target := -1
		for st in plan:
			var idx := int(st["idx"])
			var atk := int((st["action"] as Dictionary).get("atk", -1))
			if atk < 0:
				continue
			if idx == 0:
				poke_target = atk
			elif idx == 1:
				heavy_target = atk
		print("PROBE|ARM|%s|w=%.1f|break_val=%.2f|bd24=%.2f|shield_up=%s|poke_hit_shield=%s|poke_target=%d|heavy_target=%d|score=%.2f|steps=%d|ms=%d" % [
			tag, float(w), float(end.shield_break_val), bd24, str(shield_up),
			str(poke_target == 2), poke_target, heavy_target, float(ai._evaluate(end, true)), plan.size(), ms])
		print("PROBE|PLAN|%s|w=%.1f|%s" % [tag, float(w), _plan_txt(root, plan)])

func _plan_txt(root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		var who := "?"
		if atk >= 0 and atk < root.units.size():
			who = String(root.units[atk].name)
		txt += "%s[->%s,atk=%s] " % [String(root.units[idx].name),
			("原地" if mv == null else str(mv)), (who if atk >= 0 else str(atk))]
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
