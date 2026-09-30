extends Node
## 【2026-09-29 晚·一次性探针·只读】拿用户贴的 `[战局转储]` 行**原样重建**这一回合，然后跑
##   `ORDER_POLISH` 关 / 开 两版搜索，并列打印最终计划（重点看：沉默术士 hero_34 有没有打到黄金矿工 hero_42、
##   独脚龟 hero_13 有没有把那一格占掉），以及 `last_order_polish_gain` 与思考墙钟。

const DUMP := "[战局转储] AI: hero_13@(2, 5) hp4/33 atk2 r1 mv2 m0/a0/c0 | hero_15@(0, 5) hp2/18 atk3 r1 mv3 m0/a0/c0 | hero_34@(2, 6) hp17/15 atk3 r2 mv3 m0/a0/c0　‖　玩家: hero_42@(2, 4) hp14/24 atk4 r1 mv3 m0/a0/c0 | hero_38@(2, 3) hp2/27 atk3 r1 mv2 m0/a0/c0 | hero_07@(3, 3) hp14/14 atk5 r2 mv3 m0/a0/c0　‖　碑=[]　‖　障碍=[(0, 3), (0, 4), (4, 3), (4, 4)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var p := _parse(DUMP)
	print("REP2|解析|单位 %d 个｜碑 %d｜障碍 %d" % [(p["units"] as Array).size(), (p["graves"] as Array).size(), (p["obstacles"] as Array).size()])
	for flag in [1, 0]:   # ⚠️ 故意反序：用来区分"差异跟着 flag 走"还是"跟着第几次跑走"
		await _rebuild(p)
		GameState.ai_difficulty = 3          # ⚠️ 必须在取实例**之前**设：噩梦档的两阶段搜索与权重注入走这条
		var ai = battle._make_battle_ai()
		if ai == null:
			print("REP2|键=%d|拿不到 AI" % flag)
			continue
		ai.difficulty = 3                      # 噩梦：两阶段搜索
		ai.w_order_polish = flag               # 顺序抛光 关/开
		var snap := BattleSnapshot.collect(battle)
		var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
		# 【2026-09-29 晚】先确认"跑的是不是同一套搜索"＋钉死随机源（否则 A/B 看到的是噪声）
		var rngv: Variant = ai.get("rng")
		if rngv is RandomNumberGenerator:
			(rngv as RandomNumberGenerator).seed = 20260929
		print("REP2|CFG|SEARCH_MODE=%s｜TWO_PHASE_LAYOUTS(生效)=%s｜BEAM=%s｜INNER=%s｜P1DEDUP=%s｜P2DEDUP=%s｜POLISH=%s｜种子已钉=%s" % [
			str(ai.get("w_search_mode")), str(ai.get("w_tp_layouts")), str(ai.get("w_beam")), str(ai.get("w_tp_inner")),
			str(ai.get("w_tp_dedup")), str(ai.get("w_tp_p2_dedup")), str(ai.get("w_tp_polish")), str(rngv is RandomNumberGenerator)])
		var cand_txt: Array = []
		for i in sim.units.size():
			var u2: RefCounted = sim.units[i]
			if u2 == null or not u2.alive or u2.fn != DataRegistry.Faction.ENEMY:
				continue
			var acts: Array = ai._actions_for(sim, i)
			var hittable := 0
			for a2 in acts:
				if int(a2.get("atk", -1)) >= 0:
					hittable += 1
			cand_txt.append("%s:候选%d/能打%d" % [String(u2.name), acts.size(), hittable])
		print("REP2|候选|%s" % " ｜ ".join(cand_txt))
		print("REP2|实例|id=%d｜time_budget_ms=%s" % [ai.get_instance_id(), str(ai.get("time_budget_ms"))])
		var t0 := Time.get_ticks_msec()
		var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
		var ms := Time.get_ticks_msec() - t0
		var steps: Array = []
		for st in plan:
			var a: Dictionary = st["action"]
			var atk := int(a.get("atk", -1))
			var tn := "—"
			if atk == -2:
				tn = "敲障碍" + str(a.get("atk_obs", "?"))
			elif atk >= 0 and atk < sim.units.size():
				tn = String(sim.units[atk].name) + "(血" + str(int(sim.units[atk].hp)) + ")"
			steps.append("%s→%s 打%s" % [String(sim.units[int(st["idx"])].name), str(a.get("move", null)), tn])
		print("REP2|顺序抛光=%s｜墙钟=%dms｜多赚=%.1f｜计划：%s" % [
			("开" if flag > 0 else "关"), ms, ai.last_order_polish_gain, " ｜ ".join(steps)])
	print("REP2|END")
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
		var u := battle._spawn_unit(String(d["hero"]), int(d["fn"]), d["cell"])
		if u == null:
			continue
		if int(d["hp"]) > 0:
			u.hp = int(d["hp"])
		if d.has("mv") and int(d["mv"]) > 0:
			u.move_range = int(d["mv"])
		u.moved_this_turn = bool(int(d.get("m", 0)))
		u.attacked_this_turn = bool(int(d.get("a", 0)))
		u.counter_used_this_turn = bool(int(d.get("c", 0)))
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
	d["cell"] = str_to_var("Vector2i" + String(at[1])) if at.size() > 1 else Vector2i.ZERO
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
		var v: Variant = str_to_var("Vector2i" + x)
		if v != null:
			out.append(v)
	return out
