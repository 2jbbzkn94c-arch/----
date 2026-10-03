extends Node
## 【2026-10-03·一次性探针·只读】用户那局「**赏金猎人宁愿原地敲障碍，也不愿意走出去打负墟 6 伤**」的复现与验收。
##   盘面 = 用户贴的 `[战局转储]` 原样；难度取 **4（噩梦+）** ⇒ 与实机同一条链
##   （`battle._make_battle_ai()` = fork `RL/ai/AI_Battle.gd` ＋ 注入 `RL/weights/噩梦1.json`）。
##   跑一次**真 `search()`**，打印：① 计划每一行；② 赏金猎人那一步的判定（打人 / 敲障碍）；
##   ③ AI 自己那段决策日志（`ai.last_decision_text`，里面能看到 ⑨搏命激励那一笔）。
const DUMP := "[战局转储] AI: hero_21@(4, 1) hp12/19 atk1 r2 mv2 m0/a0/c0 | hero_20@(2, 3) hp3/19 atk1 r2 mv2 m0/a0/c0 | hero_12@(3, 2) hp24/24 atk2 r1 mv2 m0/a0/c0　‖　玩家: hero_14@(2, 2) hp7/15 atk4 r1 mv2 m0/a0/c0 | hero_44@(3, 4) hp19/26 atk2 r1 mv2 m0/a0/c0 | hero_46@(4, 2) hp19/19 atk2 r1 mv2 m0/a0/c0　‖　碑=[]　‖　障碍=[(1, 5), (1, 4), (5, 5)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var p := _parse(DUMP)
	await _rebuild(p)
	GameState.ai_difficulty = 4
	var ai = battle._make_battle_ai()
	if ai == null:
		print("KH|拿不到 AI")
		get_tree().quit(0)
		return
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"], snap["obstacle"],
			snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	print("KH|难度=%d｜计划 %d 步｜墙钟 %d ms" % [int(GameState.ai_difficulty), plan.size(), ms])
	var bounty_step := "（计划里没有它）"
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var u: Object = sim.units[idx]
		var nm := String(u.name) if u != null else "?"
		var what := ""
		if a.has("atk_obs"):
			what = "敲障碍 0基%s（界面%s）" % [str(a["atk_obs"]), str(_ui(a["atk_obs"]))]
		elif int(a.get("atk", -1)) >= 0:
			var tg: Object = sim.units[int(a["atk"])]
			what = "打 %s" % (String(tg.name) if tg != null else "?")
		else:
			what = "空过"
		var mv := "（原地）" if a.get("move") == null else ("走到 界面%s" % str(_ui(a["move"])))
		print("KH|   %s：%s ｜ %s" % [nm, mv, what])
		if nm.contains("赏金"):
			bounty_step = what
	print("KH|判定｜赏金猎人 = %s ⇒ %s" % [bounty_step, ("⚠️ 敲障碍" if bounty_step.begins_with("敲障碍") else "✅ 打人")])
	# —— 机制直读：两种"出手"各自的 ⑨搏命激励（用户的问题就出在这一项上）——
	var bi := -1
	var ti := -1
	for i in sim.units.size():
		var u3 = sim.units[i]
		if u3 == null or not u3.alive:
			continue
		if u3.fn == DataRegistry.Faction.ENEMY and String(u3.name).contains("赏金"):
			bi = i
		if u3.fn != DataRegistry.Faction.ENEMY and String(u3.name).contains("负墟"):
			ti = i
	if bi >= 0:
		var s_obs = sim.clone()
		ai._apply(s_obs, bi, { "atk_obs": Vector2i(0, 3) })
		var bd_obs: Dictionary = ai._eval_breakdown(s_obs)
		print("KH|A 敲障碍(界面1,4)：⑨搏命激励 = %+.1f ｜ 末态总分 = %+.1f" % [
			float(bd_obs.get("⑨搏命激励", 0.0)), ai._evaluate(s_obs, true)])
		if ti >= 0:
			var s_atk = sim.clone()
			ai._apply(s_atk, bi, { "move": Vector2i(1, 4), "atk": ti })   # 界面 (2,5) → 0 基 (1,4)
			var bd_atk: Dictionary = ai._eval_breakdown(s_atk)
			print("KH|B 走到(2,5)打负墟：⑨搏命激励 = %+.1f ｜ 末态总分 = %+.1f" % [
				float(bd_atk.get("⑨搏命激励", 0.0)), ai._evaluate(s_atk, true)])
	else:
		print("KH|⚠️ 场上找不到赏金猎人（机制直读跳过）")
	if ai.last_decision_text != "":
		print("KH|—— 决策日志 ——")
		print(ai.last_decision_text)
	print("KH|END")
	get_tree().quit(0)

## 引擎 0 基 → 界面口径（转储行里是界面口径，日志也按界面打）
func _ui(c) -> Vector2i:
	var v: Vector2i = c
	return Vector2i(v.x + DataRegistry.CELL_DISPLAY_OFFSET, v.y + DataRegistry.CELL_DISPLAY_OFFSET)

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
