extends Node
## 【2026-09-24 一次性探针】⑯猛毒新挂（`POISON_APPLY_W`）的**行为**自检 —— 跑完即退，**不改任何生产代码**。
##
## 回答 §五 T26 的问题：⑯ 那句「**我又毒了一个新人**」的动作钱，到底有没有让它**把毒铺开**？
##   机制：`_apply` 里毒蛇命中且**目标原本没毒**才 `+1` ⇒ 打**已经中毒**的人 ⑯ 一分不给
##   （而 ⑫ 计价的是"毒在场上"的**状态** ⇒ 打同一个人第二次，两项都不给钱）。
##   §14#154 就是"毒蛇咬一口就走"那件事，⑯ 正是当年为它补的动作钱。
##
## ⚠️ **基线必须用 `噩梦_测毒.json`**：`POISON_APPLY_W` 走 `_wh(施加者.hero_id, key, 扁平兜底)`，
##   而 `噩梦.json` 的 `hero_03` 段写着 3.0 ⇒ 拿它跑 theta 会被**段里的值压住**（2026-09-24 实测踩过，
##   见 §五 T25）。`噩梦_测毒.json` 已剥掉 `hero_03` 段 ⇒ 扁平注入才真正生效。
##
## 盘面：AI = 毒蛇淑女(攻1) + 巨剑；玩家 = **塔盾（已经中毒）** + 火枪手（干净）——两只都够得到。
##   于是"打谁"成了 ⑯ 的直接选择题：打已中毒的 ⇒ ⑯ 不给钱；改打干净的 ⇒ ⑯ 给钱。
## 每臂（0 / 3 / 6）跑一次 `search()`，落到终局后量：
##   · `applied` = 终局 `sim.poison_applied`（本回合**新挂上**毒的个数）
##   · `apply_val` = `sim.poison_apply_val`（⑯ 累加的实际金额）· `bd16` = `_eval_breakdown` 的 ⑯ 项
##   · `bd12` = ⑫ 项（状态钱，跨臂应基本不变）
##   · `snake_target` = 毒蛇这一回合打了谁（2 = 已中毒的塔盾 / 3 = 干净的火枪手 / -1 = 没出手）
##   · `poisoned_n` = 终局玩家侧中毒人数（"毒铺开了几个"）
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag poapply -TimeoutSec 900 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/上毒动作钱自检.tscn')
## 输出：每行 `PROBE|...`，末尾 `PROBE|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦_测毒.json"   # ⚠️ 必须是剥掉 hero_03 段的测试基线（见上）
const SEARCH_CAP_MS := 30000
const ARMS := [0.0, 3.0, 6.0]   # 3.0 = 现役

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	_nm = _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|weights=%s|flat_POISON_APPLY_W=%s|flat_POISON_TICK_VALUE=%s|has_hero03_section=%s|cap_ms=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS,
		str(_nm.get("POISON_APPLY_W", -1)), str(_nm.get("POISON_TICK_VALUE", -1)),
		str(_nm.has("hero_03")), SEARCH_CAP_MS])
	# P1：已中毒的塔盾(血厚) 与 干净的火枪手(血薄) **都能打到** ⇒ 看它往哪儿打
	_case("P1_两只都够得到", Vector2i(1, 3), Vector2i(3, 3))
	# P2：**干净的更远一格** ⇒ ⑯ 要给钱还得先走过去（考验"愿不愿意为铺毒花步数"）。
	#   ⚠️ 前两版都摆错了位置：(4,4) 与 (2,4) 都**超出毒蛇 emove=2 的射程** ⇒ 那两组只说明"够不到"、
	#   不说明"不愿去"。现在改成 脏的 (1,2)（**脚边、原地就能打**）+ 干净的 (3,2)（**要走 2 格**）——
	#   这才是真正的取舍：⑯ 到底够不够让它为铺毒花掉移动。
	_case("P2_脏的在脚边_干净的走两格", Vector2i(1, 2), Vector2i(3, 2))
	print("PROBE|END")
	get_tree().quit(0)

func _case(tag: String, dirty_cell: Vector2i, clean_cell: Vector2i) -> void:
	var descs: Array = []
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_03", Vector2i(1, 1), "毒蛇"))
	descs.append(_desc(DataRegistry.Faction.ENEMY, "hero_12", Vector2i(3, 1), "巨剑"))
	var dirty := _desc(DataRegistry.Faction.PLAYER, "hero_11", dirty_cell, "已中毒敌")
	dirty["poisoned"] = true
	descs.append(dirty)
	descs.append(_desc(DataRegistry.Faction.PLAYER, "hero_09", clean_cell, "干净敌"))
	var built := _build(descs)
	var ai = built["ai"]
	var root = built["sim"]
	print("PROBE|POS|%s|snake_eatk=%d|snake_emove=%d|dirty_at=%s(距毒蛇%d)|clean_at=%s(距毒蛇%d)|dirty_start_poisoned=%s" % [
		tag, int(root.units[0].eatk), int(root.units[0].emove), str(dirty_cell), int(_grid.distance(root.units[0].cell, dirty_cell)),
		str(clean_cell), int(_grid.distance(root.units[0].cell, clean_cell)), str(root.units[2].poisoned)])
	for w in ARMS:
		ai.set_weights({ "POISON_APPLY_W": float(w) })
		var s = root.clone()
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(s, DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var end = root.clone()
		for st in plan:
			ai._apply(end, int(st["idx"]), st["action"])
		var bd: Dictionary = ai._eval_breakdown(end, true)
		var snake_target := -1
		for st in plan:
			if int(st["idx"]) == 0:
				var atk := int((st["action"] as Dictionary).get("atk", -1))
				if atk >= 0:
					snake_target = atk
		var poisoned_n := 0
		for u in end.units:
			if u != null and u.alive and u.fn != DataRegistry.Faction.ENEMY and u.poisoned:
				poisoned_n += 1
		print("PROBE|ARM|%s|w=%.1f|applied=%d|apply_val=%.2f|bd16=%.2f|bd12=%.2f|snake_target=%d|poisoned_n=%d|score=%.2f|steps=%d|ms=%d" % [
			tag, float(w), int(end.poison_applied), float(end.poison_apply_val),
			float(bd.get("⑯猛毒新挂", 0.0)), float(bd.get("⑫猛毒计价", 0.0)),
			snake_target, poisoned_n, float(ai._evaluate(end, true)), plan.size(), ms])
		print("PROBE|PLAN|%s|w=%.1f|%s" % [tag, float(w), _plan_txt(root, plan)])

func _plan_txt(root, plan: Array) -> String:
	var txt := ""
	for st in plan:
		var idx := int(st["idx"])
		var act: Dictionary = st["action"]
		var mv: Variant = act.get("move")
		var atk := int(act.get("atk", -1))
		var who := "不打"
		if atk >= 0 and atk < root.units.size():
			who = String(root.units[atk].name)
		txt += "%s[->%s,atk=%s] " % [String(root.units[idx].name),
			("原地" if mv == null else str(mv)), who]
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
