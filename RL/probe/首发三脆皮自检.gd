extends Node
## 【2026-10-02·一次性探针·只读·用户「**有肉盾，为什么最后会上了三个脆皮**」】
##
## 复刻那条日志的账（敌方 8 人池：烛火/红帽/沉默术士/长剑/圣诞老人/坠炮手/装甲堡垒/波盾；
## 玩家已上阵 = 宿魂、影丸），逐个候选人打 `_deploy_candidate_value()`，
## 重点看**第三槽**（已上阵 2 人 = 烛火 + 红帽，两个低血）：
##   · 改前：`_deploy_is_hard(烛火)` = true（烛火是<后勤>）⇒ `hard_cnt=1` ⇒ 「防全脆皮」那道门**不触发**
##           ⇒ 沉默术士(72.0) 压过 装甲堡垒(69.1) ⇒ **三个脆皮**
##   · 改后：后勤不算硬身板 ⇒ `hard_cnt=0` ⇒ 第三手必须是硬身板（硬 +3 / 脆 −3）⇒ 装甲堡垒该翻上来
##
## 输出：DF|… / DF|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _rebuild()
	var pool := ["hero_17", "hero_40", "hero_34", "hero_18", "hero_02", "hero_45", "hero_48", "hero_16"]
	print("DF|池|" + "、".join(pool.map(func(h): return _nm(h))))
	var names: Array[String] = []
	for h in pool:
		var d = DataRegistry.get_hero(h)
		names.append("%s(%s·%d血·硬身板=%s)" % [_nm(h), DataRegistry.hero_role_name(h),
			int(d.max_hp), str(battle._deploy_is_hard(h))])
	print("DF|硬身板判定|" + "｜".join(names))
	# ---- 第一槽：玩家还没上人 ----
	battle.player_deployed = []
	_dump_slot(1, [])
	# ---- 第二槽：玩家上了 宿魂（hero_46）----
	battle.player_deployed = ["hero_46"]
	_dump_slot(2, ["hero_17"])
	# ---- 第三槽：玩家上了 宿魂 + 影丸；我方已上 烛火 + 红帽 ----
	battle.player_deployed = ["hero_46", "hero_07"]
	_dump_slot(3, ["hero_17", "hero_40"])
	print("DF|END")
	get_tree().quit(0)

func _dump_slot(n: int, deployed: Array) -> void:
	var rows: Array = []
	for h in ["hero_17", "hero_40", "hero_34", "hero_18", "hero_02", "hero_45", "hero_48", "hero_16"]:
		if deployed.has(h):
			continue
		rows.append({ "hid": h, "v": battle._deploy_candidate_value(String(h), deployed),
			"set": _best_set(deployed, String(h)), "hard": battle._deploy_is_hard(String(h)) })
	rows.sort_custom(func(a, b): return float(a["set"]) > float(b["set"]))
	var txt: Array = []
	for r in rows:
		txt.append("%s 整套%.1f（本槽 %.1f%s）" % [_nm(String(r["hid"])), float(r["set"]), float(r["v"]),
			("，硬" if bool(r["hard"]) else "")])
	var best: String = String(rows[0]["hid"]) if rows.size() > 0 else ""
	print("DF|槽%d|已上阵=%s ⇒ %s｜**整套最高=%s**" % [n,
		("（空）" if deployed.is_empty() else "、".join(deployed.map(func(h): return _nm(String(h))))),
		"｜".join(txt), _nm(best)])

## 整套口径（与实机日志那一行同款）：本候选 ＋ 其余按最优补齐 ⇒ 取最高的一套
func _best_set(deployed: Array, cand: String) -> float:
	var rest: Array = []
	for h in ["hero_17", "hero_40", "hero_34", "hero_18", "hero_02", "hero_45", "hero_48", "hero_16"]:
		if h != cand and not deployed.has(h):
			rest.append(h)
	var need: int = 3 - (deployed.size() + 1)
	var best := -INF
	for combo in battle._combos_of(rest, need):
		var ids: Array = deployed.duplicate()
		ids.append(cand)
		ids.append_array(combo)
		best = maxf(best, battle._deploy_set_value(ids))
	return best

func _nm(hid: String) -> String:
	var d = DataRegistry.get_hero(hid)
	return String(d.display_name) if d != null else hid

func _rebuild() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 6:
		await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	battle._session_id += 1      # 作废 Main.tscn 自带的对局 prologue
	for i in 6:
		await get_tree().process_frame
