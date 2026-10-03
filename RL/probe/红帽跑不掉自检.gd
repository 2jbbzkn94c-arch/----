extends Node
## 【2026-10-03·一次性探针·只读】用户那局「**AI 已经死两个了，红帽为什么不找独脚龟躲起来、而是去打人然后被反击死**」的查证。
##   做法：照 `[战局转储]` 复刻，并照该局 AI 自己的计划先把两个队友走掉（**独脚龟 → 界面(2,5)**、
##   **波盾 → 界面(1,5)**）—— 那才是红帽做决定时的场面；然后
##     ① 打印 `_was_doomed(红帽)`（"逃不掉且必死"的引擎判据）；
##     ② 把她**每一个走得到的格子**挨个问 `_incoming_total_on()`（含逐笔来源）并标出哪些格**不致命**（< 她的血）。
##   ⇒ 若一个不致命的格都没有，"躲起来"在这张盘上**不成立**（她真跑不掉）；只要有一个，"反正跑不掉"就是错的。
##   盘面（界面口径）：红帽 hero_40 (1,4) 2血 · 波盾 hero_16 (1,7) · 独脚龟 hero_13 (2,7)
##     玩家：傀儡师 hero_05 (3,3) 攻3 射2 mv2 · 装甲堡垒 hero_48 (2,4) 攻1 嘲讽 · 鼠队长 hero_04 (2,3) 攻4 mv3
const DUMP := "[战局转储] AI: hero_40@(1, 4) hp2/13 atk5 r1 mv2 m0/a0/c0 | hero_16@(1, 7) hp16/16 atk4 r1 mv2 m0/a0/c0 | hero_13@(2, 7) hp29/33 atk2 r1 mv2 m0/a0/c0　‖　玩家: hero_05@(3, 3) hp21/19 atk3 r2 mv2 m0/a0/c0 | hero_48@(2, 4) hp15/36 atk1 r1 mv2 m0/a0/c0 | hero_04@(2, 3) hp7/18 atk4 r1 mv3 m0/a0/c0　‖　碑=[]　‖　障碍=[]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var p := _parse(DUMP)
	await _rebuild(p)
	# 用户口径「AI 已经死两个了」⇒ 把累计阵亡也照实填上（转储行里没有这两笔）
	battle.enemy_dead = 2
	battle.player_dead = 0
	GameState.ai_difficulty = 4
	var ai = battle._make_battle_ai()
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"], snap["obstacle"],
			snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}), snap.get("deads", {}))
	print("RH|deads = %s ｜ 判负线 = %d" % [str(snap.get("deads", {})), int(sim.death_line)])
	# 照该局计划先把两个队友走掉（这才是她做决定时的场面）
	for mv in [["hero_13", Vector2i(1, 4)], ["hero_16", Vector2i(0, 4)]]:   # 界面(2,5) / 界面(1,5) − 1
		for i in sim.units.size():
			var u0 = sim.units[i]
			if u0 != null and u0.alive and String(u0.hero_id) == String(mv[0]):
				ai._apply(sim, i, { "move": mv[1] })
				print("RH|先手：%s 走到 %s" % [String(u0.name), str(_ui(mv[1]))])
	var her = null
	var hi := -1
	for i in sim.units.size():
		var u = sim.units[i]
		if u != null and u.alive and String(u.hero_id) == "hero_40":
			her = u
			hi = i
	if her == null:
		print("RH|盘上没有红帽")
		get_tree().quit(0)
		return
	print("RH|红帽 @%s hp%d emove%d ｜ `_was_doomed` = %s" % [
		str(_ui(her.cell)), int(her.hp), int(her.emove), str(ai._was_doomed(sim, her))])
	var cells: Array = [her.cell]
	for c in ai._sim_walk_cells(sim, her.cell, int(her.emove), her.skills.has(DataRegistry.Skill.INFILTRATE)):
		cells.append(c)
	print("RH|她这一回合走得到的格（含原地）共 %d 个，逐个问「下回合会挨多少」：" % cells.size())
	var safe := 0
	for c in cells:
		var info := {}
		var inc: float = ai._incoming_total_on(sim, her, c, info)
		var parts: Array[String] = []
		for pt in (info.get("parts", []) as Array):
			if pt is Array and (pt as Array).size() >= 2:
				parts.append("%s%.0f" % [String(pt[0]), float(pt[1])])
		var lethal := inc >= float(her.hp)
		if not lethal:
			safe += 1
		print("RH|   %s%s 挨 %.0f 伤 %s ⇒ %s" % [_ui(c), ("（原地）" if c == her.cell else ""), inc,
			("（%s）" % "＋".join(parts)) if parts.size() > 0 else "", "⚠️致命" if lethal else "✅**安全**"])
	print("RH|判定｜不致命的格 = %d 个 ⇒ %s" % [safe,
		"✅ 有地方躲（引擎说「跑不掉」是错的）" if safe > 0 else "她真跑不掉（这张盘上没有任何一格能活）"])
	# —— 追加：**假如那条后路没被自己人堵住**，她退到后排会不会活？（只问挨打，不管走不走得到）——
	print("RH|假如后路是通的（只问挨打，不管走不走得到）：")
	for c2 in [Vector2i(0, 4), Vector2i(0, 5), Vector2i(1, 5), Vector2i(0, 6)]:   # 界面 (1,5) (1,6) (2,6) (1,7)
		var info2 := {}
		var inc2: float = ai._incoming_total_on(sim, her, c2, info2)
		var parts2: Array[String] = []
		for pt2 in (info2.get("parts", []) as Array):
			if pt2 is Array and (pt2 as Array).size() >= 2:
				parts2.append("%s%.0f" % [String(pt2[0]), float(pt2[1])])
		var holder = sim.occ.get(c2, null)
		print("RH|   %s 挨 %.0f 伤 %s ⇒ %s（那格现在：%s）" % [_ui(c2), inc2,
			("（%s）" % "＋".join(parts2)) if parts2.size() > 0 else "",
			"⚠️致命" if inc2 >= float(her.hp) else "✅**安全**",
			(String(holder.name) + " 站着") if holder != null else "空"])
	print("RH|END")
	print("RH|—— 真搜索（deads 已按实机填 2/0/3）——")
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("RH|计划 %d 步｜墙钟 %d ms" % [plan.size(), Time.get_ticks_msec() - t0])
	for st in plan:
		var idx := int(st["idx"])
		var a: Dictionary = st["action"]
		var uu: Object = sim.units[idx]
		var nm := String(uu.name) if uu != null else "?"
		var what := "空过"
		if a.has("atk_obs"):
			what = "敲障碍 " + str(_ui(a["atk_obs"]))
		elif int(a.get("atk", -1)) >= 0:
			var tg: Object = sim.units[int(a["atk"])]
			what = "打 " + (String(tg.name) if tg != null else "?")
		var mv := "（原地）" if a.get("move") == null else ("走到 " + str(_ui(a["move"])))
		print("RH|   %s：%s ｜ %s" % [nm, mv, what])
	# —— 对照：把"她退到界面(1,6)"与"搜索选的这条计划"摆在**同一个末态口径**上比 ——
	var s_plan = sim.clone()
	for st2 in plan:
		ai._apply(s_plan, int(st2["idx"]), st2["action"])
	var s_ret = sim.clone()
	ai._apply(s_ret, hi, { "move": Vector2i(0, 5) })     # 界面 (1,6) → 0 基 (0,5)
	var bd_p: Dictionary = ai._eval_breakdown(s_plan)
	var bd_r: Dictionary = ai._eval_breakdown(s_ret)
	print("RH|对照｜搜索的计划：末态 %+.1f（红帽存活 %s · ⑩终局 %+.1f）" % [
		ai._evaluate(s_plan, true), str((s_plan.units[hi] as Object).alive), float(bd_p.get("⑩终局项", 0.0))])
	print("RH|对照｜她退到 (1,6)：末态 %+.1f（红帽存活 %s · ⑩终局 %+.1f）" % [
		ai._evaluate(s_ret, true), str((s_ret.units[hi] as Object).alive), float(bd_r.get("⑩终局项", 0.0))])
	print("RH|对照｜差值（撤退 − 计划）= %+.1f" % [ai._evaluate(s_ret, true) - ai._evaluate(s_plan, true)])
	print("RH|权重｜w_terminal = %s ｜ w_risk = %s ｜ w_exposure = %s ｜ w_form_escape = %s" % [
		str(ai.w_terminal), str(ai.w_risk), str(ai.w_exposure_total), str(ai.w_form_escape)])
	print("RH|阵亡账｜sim.my_dead = %d ｜ sim.foe_dead = %d ｜ line = %d" % [int(sim.my_dead), int(sim.foe_dead), int(sim.death_line)])
	print("RH|阵亡账｜计划态 my=%d foe=%d ｜ 撤退态 my=%d foe=%d ｜ line=%d" % [int(s_plan.my_dead), int(s_plan.foe_dead), int(s_ret.my_dead), int(s_ret.foe_dead), int(sim.death_line)])
	print("RH|_terminal_value｜计划态 = %+.1f ｜ 撤退态 = %+.1f" % [ai._terminal_value(s_plan), ai._terminal_value(s_ret)])
	print("RH|⑩终局项 有键 = %s ｜ 计划态 %s ｜ 撤退态 %s" % [str(bd_p.has("⑩终局项")), str(bd_p.get("⑩终局项", "缺")), str(bd_r.get("⑩终局项", "缺"))])
	get_tree().quit(0)

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

func _cv(c) -> Vector2i:
	if typeof(c) != TYPE_VECTOR2I:
		return Vector2i.ZERO
	var v: Vector2i = c
	return Vector2i(v.x - DataRegistry.CELL_DISPLAY_OFFSET, v.y - DataRegistry.CELL_DISPLAY_OFFSET)
