extends Node
## 【2026-10-03·一次性探针·只读】用户那局「白游侠下回合挨 5 伤？」的复现与对拍 —— 只量 `_incoming_total_on()`。
##   两张盘**只差一格障碍**：
##     A = 白游侠还没敲掉自己身边那面墙（障碍仍含 (1,5)）⇒ 真开火位只剩 (2,5) ⇒ 期望 **2** 伤
##     B = 真末态（(1,5) 被它自己敲掉）⇒ 开火位 (2,5) ＋ (1,5)，但 (1,5) 只有毒蛇淑女走得到 ⇒ 期望 **3** 伤
##   ⚠️ 同时打印每个敌人的**可用开火位**（`_threat_fire_cells()`）与逐笔 `parts` ⇒ "一格一人"的指派到底削掉了谁，一眼可见。
##   盘面取自用户 `[战局转储]` + 那份决策日志（AI 计划：白游侠 (1,2)→(2,4)、敲 (1,5)；(4,3) 那步敲掉 (5,4)）。
const DUMP_A := "[战局转储] AI: hero_10@(2, 4) hp19/19 atk2 r2 mv3 m0/a0/c0 | hero_01@(4, 3) hp27/27 atk3 r1 mv2 m0/a0/c0 | hero_49@(3, 4) hp22/22 atk2 r1 mv2 m0/a0/c0　‖　玩家: hero_02@(5, 7) hp24/24 atk2 r1 mv3 m0/a0/c0 | hero_12@(3, 7) hp24/24 atk2 r1 mv2 m0/a0/c0 | hero_03@(1, 7) hp21/21 atk1 r1 mv2 m0/a0/c0　‖　碑=[]　‖　障碍=[(1, 4), (1, 5), (5, 5)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"
const DUMP_B := "[战局转储] AI: hero_10@(2, 4) hp19/19 atk2 r2 mv3 m0/a0/c0 | hero_01@(4, 3) hp27/27 atk3 r1 mv2 m0/a0/c0 | hero_49@(3, 4) hp22/22 atk2 r1 mv2 m0/a0/c0　‖　玩家: hero_02@(5, 7) hp24/24 atk2 r1 mv3 m0/a0/c0 | hero_12@(3, 7) hp24/24 atk2 r1 mv2 m0/a0/c0 | hero_03@(1, 7) hp21/21 atk1 r1 mv2 m0/a0/c0　‖　碑=[]　‖　障碍=[(1, 4), (5, 5)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	for pair in [["A 未敲墙（(1,5) 还是障碍）", DUMP_A], ["B 真末态（(1,5) 被敲掉）", DUMP_B]]:
		var p := _parse(String(pair[1]))
		await _rebuild(p)
		GameState.ai_difficulty = 3
		var ai = battle._make_battle_ai()
		ai.difficulty = 3
		var snap := BattleSnapshot.collect(battle)
		var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"], snap["obstacle"],
				snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
		var me := -1
		for i in sim.units.size():
			var u2 = sim.units[i]
			if u2 != null and u2.alive and String(u2.hero_id) == "hero_10":
				me = i
		if me < 0:
			print("XW|—— %s —— 盘上没有白游侠" % String(pair[0]))
			continue
		var tu = sim.units[me]
		print("XW|—— %s ——" % String(pair[0]))
		print("XW|白游侠 @%s hp%d ｜ 敌人的可用开火位（`_threat_fire_cells`）：" % [DataRegistry.cell_txt(tu.cell), int(tu.hp)])
		for i in sim.units.size():
			var e = sim.units[i]
			if e == null or not e.alive or e.fn == tu.fn:
				continue
			var cells: Array = ai._threat_fire_cells(sim, e, tu.cell, tu)
			var txt: Array[String] = []
			for c in cells:
				txt.append(DataRegistry.cell_txt(c))
			print("XW|   %s（有效攻%d·射程%d·mv%d）开火位 %d 个：%s" % [
				String(e.name), int(e.eatk), int(e.atk_range), int(e.emove), cells.size(),
				("、".join(txt) if txt.size() > 0 else "—")])
		var info := {}
		var inc: float = ai._incoming_total_on(sim, tu, tu.cell, info)
		var ps: Array[String] = []
		for pt in (info.get("parts", []) as Array):
			if pt is Array and (pt as Array).size() >= 2:
				ps.append("%s %.0f" % [String(pt[0]), float(pt[1])])
		print("XW|   ⇒ 挨打合计 = %.1f 伤（逐笔：%s）" % [inc, ("＋".join(ps) if ps.size() > 0 else "—")])
	print("XW|END")
	get_tree().quit(0)

func _rebuild(p: Dictionary) -> void:
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
	for ud in p["units"]:
		var d: Dictionary = ud
		var u2 := battle._spawn_unit(String(d["hero"]), int(d["fn"]), d["cell"])
		if u2 == null:
			continue
		if int(d["hp"]) > 0:
			u2.hp = int(d["hp"])
		if d.has("mv") and int(d["mv"]) > 0:
			u2.move_range = int(d["mv"])
		u2.moved_this_turn = bool(int(d.get("m", 0)))
		u2.attacked_this_turn = bool(int(d.get("a", 0)))
		u2.counter_used_this_turn = bool(int(d.get("c", 0)))
	for c in p["obstacles"]:
		battle.obstacles[c] = 2
	for c in p["graves"]:
		battle.graves[c] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()

func _parse(line: String) -> Dictionary:
	var out := { "units": [], "graves": [], "obstacles": [] }
	var body := line.substr(String("[战局转储]").length())
	for seg0 in body.split("　‖　"):
		var seg := String(seg0).strip_edges()
		if seg.begins_with("AI:") or seg.begins_with("玩家:"):
			var fn := DataRegistry.Faction.ENEMY if seg.begins_with("AI:") else DataRegistry.Faction.PLAYER
			for one in seg.split(":", true, 1)[1].split("|"):
				var t := String(one).strip_edges()
				if t == "":
					continue
				out["units"].append(_unit(t, fn))
		elif seg.begins_with("障碍="):
			out["obstacles"] = _cells(seg.substr(3))
		elif seg.begins_with("碑="):
			out["graves"] = _cells(seg.substr(2))
	return out

func _unit(t: String, fn: int) -> Dictionary:
	var d := { "fn": fn, "hero": "", "cell": Vector2i.ZERO, "hp": -1, "mv": -1, "m": 0, "a": 0, "c": 0 }
	var sp := t.find(" hp")
	var head := (t.substr(0, sp) if sp > 0 else t)
	var at := head.split("@")
	d["hero"] = String(at[0])
	d["cell"] = _cv(str_to_var("Vector2i" + String(at[1]))) if at.size() > 1 else Vector2i.ZERO
	for tok in t.split(" "):
		var s := String(tok)
		if s.begins_with("hp"):
			d["hp"] = int(s.substr(2).split("/")[0])
		elif s.begins_with("mv"):
			d["mv"] = int(s.substr(2))
		elif s.begins_with("m") and s.contains("/a"):
			var mm := s.split("/")
			if mm.size() >= 3:
				d["m"] = int(String(mm[0]).substr(1))
				d["a"] = int(String(mm[1]).substr(1))
				d["c"] = int(String(mm[2]).substr(1))
	return d

func _cells(t: String) -> Array:
	var out: Array = []
	var s := t.strip_edges()
	if s.length() < 3:
		return out
	s = s.substr(1, s.length() - 2)
	for one in s.split("),"):
		var x := String(one).strip_edges()
		if x == "":
			continue
		if not x.ends_with(")"):
			x += ")"
		var v: Vector2i = _cv(str_to_var("Vector2i" + x))
		out.append(v)
	return out

## 【2026-10-01】转储行里的坐标是**界面口径**（左上角 =(1, 1)）⇒ 这里 −1 换回引擎 0 基。
func _cv(c) -> Vector2i:
	if typeof(c) != TYPE_VECTOR2I:
		return Vector2i.ZERO
	var v: Vector2i = c
	return Vector2i(v.x - DataRegistry.CELL_DISPLAY_OFFSET, v.y - DataRegistry.CELL_DISPLAY_OFFSET)
