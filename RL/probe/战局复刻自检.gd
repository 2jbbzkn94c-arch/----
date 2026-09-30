extends Node
## 【2026-09-29 晚·一次性探针·只读·自校验】`[战局转储]` 那一行**能不能把盘面原样重建**。
##   做法（不需要用户贴任何东西就能自证）：
##     ① 摆一个盘面（含状态/碑/障碍/双方单位）→ 调 `battle._log_state_dump()` 打出转储行；
##     ② 把**打出来的那一行**解析回盘面（单位 id/格/血/攻射移/三个回合标记/状态 + 碑/障碍）；
##     ③ 逐单位对比"重建前的盘面"与"重建后的盘面"，并打印最近一条转储行原文。
##   ⇒ 通过 = 以后用户贴一行给我，我就能照它重建同一局面。

var battle: Battle
var dumped := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _fresh()
	# ① 摆一个"有状态、有碑、有障碍、双方都有单位"的盘面
	var a := battle._spawn_unit("hero_46", DataRegistry.Faction.ENEMY, Vector2i(0, 1))
	var b := battle._spawn_unit("hero_20", DataRegistry.Faction.ENEMY, Vector2i(2, 1))
	var c := battle._spawn_unit("hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 4))
	battle._spawn_unit("hero_48", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	for i in 3:
		await get_tree().process_frame
	if a != null:
		a.hp = 17
		a.add_status(StatusDB.SOLID)
		a.moved_this_turn = true
	if b != null:
		b.hp = 9
		b.counter_used_this_turn = true
	if c != null:
		c.add_status(StatusDB.SHIELD)
	battle.graves[Vector2i(1, 3)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	battle.obstacles[Vector2i(4, 2)] = 2
	battle.player_deployed = ["hero_23"]
	battle.enemy_pool = ["hero_11", "hero_30"]
	for i in 2:
		await get_tree().process_frame
	print("REPRO|摆盘|%s" % _board_txt())
	# ② 打转储行并解析重建
	dumped = battle._state_dump_line()
	for i in 2:
		await get_tree().process_frame
	print("REPRO|转储行|%s" % dumped)
	var parsed := _parse_dump(dumped)
	var before := _board_txt()
	await _rebuild(parsed)
	var after := _board_txt()
	var ok := before == after
	print("REPRO|对比|重建前=%s" % before)
	print("REPRO|对比|重建后=%s" % after)
	print("REPRO|结论|%s" % ("PASS（转储行 = 可原样重建）" if ok else "FAIL（重建结果与原始盘面不一致）"))
	print("REPRO|END")
	get_tree().quit(0)

func _fresh() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
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
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame

## 盘面的规范化文本（逐单位排序后拼），用来对比"重建前/后"是否一致
func _board_txt() -> String:
	var rows: Array = []
	for u in battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		var sts: Array = []
		for sk in u.statuses.keys():
			sts.append(String(sk))
		sts.sort()
		rows.append("%s@%s hp%d/%d a%d r%d m%d/%d/%d %s" % [
			String(u.hero_id), str(u.cell), int(u.hp), int(u.max_hp), int(u.effective_atk()),
			int(u.attack_range), int(u.moved_this_turn), int(u.attacked_this_turn),
			int(u.counter_used_this_turn), ",".join(sts)])
	rows.sort()
	return "｜".join(rows) + "｜碑" + str(_sorted_keys(battle.graves)) + "｜障" + str(_sorted_keys(battle.obstacles))

func _sorted_keys(d: Dictionary) -> Array:
	var ks: Array = []
	for k in d.keys():
		ks.append(str(k))
	ks.sort()
	return ks

## 解析转储行：`[战局转储] AI: hero_46@(0, 1) hp17/24 atk5 r1 mv3 m1/a0/c0 st=solid | …　‖　碑=[…] ‖ 障碍=[…]`
func _parse_dump(line: String) -> Dictionary:
	var out := { "units": [], "graves": [], "obstacles": [] }
	if not line.begins_with("[战局转储]"):
		return out
	var body := line.substr(String("[战局转储]").length())
	var segs := body.split("　‖　")
	for i in segs.size():
		var seg := String(segs[i]).strip_edges()
		if seg.begins_with("AI:") or seg.begins_with("玩家:"):
			var fn := DataRegistry.Faction.ENEMY if seg.begins_with("AI:") else DataRegistry.Faction.PLAYER
			var us := seg.split(":", true, 1)[1]
			for one in us.split("|"):
				var t := String(one).strip_edges()
				if t == "":
					continue
				out["units"].append(_parse_unit(t, fn))
		elif seg.begins_with("碑="):
			out["graves"] = _parse_cells(seg.substr(2))
		elif seg.begins_with("障碍="):
			out["obstacles"] = _parse_cells(seg.substr(3))
	return out

func _parse_unit(t: String, fn: int) -> Dictionary:
	var d := { "fn": fn, "hero": "", "cell": Vector2i.ZERO, "hp": -1, "st": [], "m": 0, "a": 0, "c": 0 }
	var sp := t.find(" hp")                            # ⚠️ 格子文本里**带空格**（`(0, 1)`）⇒ 不能按空格切 head
	var head := (t.substr(0, sp) if sp > 0 else t)     # hero_46@(0, 1)
	var at := head.split("@")
	d["hero"] = String(at[0])
	d["cell"] = str_to_var("Vector2i" + String(at[1])) if at.size() > 1 else Vector2i.ZERO
	for tok in t.split(" "):
		var s := String(tok)
		if s.begins_with("hp"):
			d["hp"] = int(s.substr(2).split("/")[0])
		elif s.begins_with("m") and s.contains("/a"):
			var mm := s.split("/")   # 转储里的 `m1/a0/c0` = 已移动/已出手/已反击
			if mm.size() >= 3:
				d["m"] = int(String(mm[0]).substr(1))
				d["a"] = int(String(mm[1]).substr(1))
				d["c"] = int(String(mm[2]).substr(1))
		elif s.begins_with("st="):
			d["st"] = s.substr(3).split(",")
	return d

func _parse_cells(t: String) -> Array:
	var out: Array = []
	var s := t.strip_edges()
	if s.length() < 3:
		return out
	s = s.substr(1, s.length() - 2)                   # 去掉 [ ]
	for one in s.split("),"):
		var x := String(one).strip_edges()
		if x == "":
			continue
		if not x.ends_with(")"):
			x += ")"
		var v: Variant = str_to_var("Vector2i" + x)
		if v != null:
			out.append(v)
	return out

## 按解析结果重建盘面（只重建"能被转储表达"的部分：单位/位置/血量/状态 + 碑/障碍）
func _rebuild(p: Dictionary) -> void:
	await _fresh()
	for ud in p["units"]:
		var d: Dictionary = ud
		var u := battle._spawn_unit(String(d["hero"]), int(d["fn"]), d["cell"])
		if u == null:
			continue
		if int(d["hp"]) > 0:
			u.hp = int(d["hp"])
			u._update_hp_label()
		u.moved_this_turn = bool(int(d.get("m", 0)))
		u.attacked_this_turn = bool(int(d.get("a", 0)))
		u.counter_used_this_turn = bool(int(d.get("c", 0)))
		for st in (d["st"] as Array):
			u.add_status(String(st))
	for c in p["graves"]:
		battle.graves[c] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	for c in p["obstacles"]:
		battle.obstacles[c] = 2
	for i in 3:
		await get_tree().process_frame
