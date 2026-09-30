extends Node
## 【2026-09-29 晚·一次性探针·只读】用用户那行转储复刻盘面，跑 `sub_by_search` 关/开：
##   看替补选人选了谁（期望：开着时选出"小阴影 hero_15"那种能凑出连环杀的人）。
const DUMP := "[战局转储] AI: hero_18@(2, 6) hp7/18 atk3 r1 mv3 m0/a0/c0 | hero_40@(1, 5) hp11/13 atk5 r1 mv2 m0/a0/c0 | hero_21@(2, 4) hp19/19 atk1 r2 mv2 m0/a0/c0　‖　玩家: hero_30@(1, 3) hp11/20 atk3 r1 mv2 m0/a0/c0 | hero_41@(3, 3) hp11/24 atk2 r3 mv2 m0/a0/c0 | hero_44@(2, 5) hp1/26 atk2 r1 mv2 m0/a0/c0　‖　碑=[]　‖　障碍=[(0, 4), (0, 3), (4, 4), (4, 3)]　‖　炸弹=[]　‖　buff格=[]　‖　金矿=[]"
const ROSTER := ["hero_15", "hero_21", "hero_38", "hero_42"]
var battle: Battle
func _ready() -> void:
	_run.call_deferred()
func _run() -> void:
	GameState.ai_difficulty = 3
	for bud in [800]:   # 只跑一档（链条验证不需要扫预算，省时间）
		await _rebuild()
		battle.enemy_roster = ROSTER.duplicate()
		# battle.sub_by_search = 1   # 故意注释掉：验证"只写在权重文件里"也能生效
		battle.sub_by_search_ms = bud
		battle.player_dead = 1
		battle.enemy_dead = 0
		battle._pending_enemy_sub = 1
		var before := {}
		for u in battle.units:
			before[u.get_instance_id()] = true
		var t0 := Time.get_ticks_msec()
		battle._place_enemy_sub()
		for i in 40:
			await get_tree().process_frame
		var ms := Time.get_ticks_msec() - t0
		var landed := ""
		for u in battle.units:
			if u != null and is_instance_valid(u) and u.alive and not before.has(u.get_instance_id()):
				landed = String(u.hero_id)
				break
		print("AB|预算=%dms｜墙钟=%dms｜实际上场=%s" % [bud, ms, landed])
	await _chain_check()
	print("AB|END")
	get_tree().quit(0)
func _rebuild() -> void:
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
	battle.units.clear(); battle.occupancy.clear(); battle.graves.clear(); battle.obstacles.clear(); battle.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	var body := DUMP.substr(String("[战局转储]").length())
	for seg0 in body.split("　‖　"):
		var seg := String(seg0).strip_edges()
		if seg.begins_with("AI:") or seg.begins_with("玩家:"):
			var fn := DataRegistry.Faction.ENEMY if seg.begins_with("AI:") else DataRegistry.Faction.PLAYER
			for one in seg.split(":", true, 1)[1].split("|"):
				var s := String(one).strip_edges()
				if s == "":
					continue
				var sp := s.find(" hp")
				var at := (s.substr(0, sp) if sp > 0 else s).split("@")
				var u2 := battle._spawn_unit(String(at[0]), fn, str_to_var("Vector2i" + String(at[1])))
				if u2 == null:
					continue
				for tok in s.split(" "):
					if String(tok).begins_with("hp"):
						u2.hp = int(String(tok).substr(2).split("/")[0])
		elif seg.begins_with("障碍="):
			for c in _cells(seg.substr(3)):
				battle.obstacles[c] = 2
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
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
func _chain_check() -> void:
	await _rebuild()
	GameState.ai_difficulty = 3
	# 【用户口径修正】这才是"2 选 1"要验的盘面：**把 AI 实际选的超新星(hero_21)拿掉**，
	#   在原格 (2,4) 放上**小阴影(hero_15)** —— 即"当时如果选小阴影会怎样"。
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and String(u.hero_id) == "hero_21":
			battle.occupancy.erase(u.cell)
			u.queue_free()
			battle.units.erase(u)
			break
	await get_tree().process_frame
	var sub := battle._spawn_unit("hero_15", DataRegistry.Faction.ENEMY, Vector2i(2, 4))
	if sub == null:
		print("CHAIN2|小阴影摆不上")
		return
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var ai = battle._make_battle_ai()
	if ai == null:
		print("CHAIN2|拿不到 AI")
		return
	ai.difficulty = 3
	# ai.w_order_polish = 1
	ai.order_polish_max_steps = 8
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var parts: Array = []
	var pdead0 := 0
	for u in sim.units:
		if u != null and not u.alive and u.fn != DataRegistry.Faction.ENEMY:
			pdead0 += 1
	# ⚠️ 按计划的**真实顺序**逐步 `_apply`，把每一刀的**伤害与结算**打出来（别再靠目标名字猜）
	for st in plan:
		var a: Dictionary = st["action"]
		var ui := int(st["idx"])
		var un := String(sim.units[ui].name) if ui >= 0 and ui < sim.units.size() else "?"
		var atk := int(a.get("atk", -1))
		if atk < 0:
			if atk == -2:
				parts.append("%s 敲障碍%s" % [un, str(a.get("atk_obs", "?"))])
			elif a.get("move", null) != null:
				parts.append("%s → %s（只走位）" % [un, str(a.get("move"))])
			continue
		if atk >= sim.units.size():
			continue
		var t: RefCounted = sim.units[atk]
		var hp0 := int(t.hp)
		var tn2 := String(t.name)
		ai._apply(sim, ui, a)
		var dead: bool = not bool(t.alive)
		parts.append("%s 打 %s：%d→%d%s" % [un, tn2, hp0, (0 if dead else int(t.hp)), ("　**击杀**" if dead else "")])
	var pdead1 := 0
	for u2 in sim.units:
		if u2 != null and not u2.alive and u2.fn != DataRegistry.Faction.ENEMY:
			pdead1 += 1
	print("CHAIN2|超新星已换成小阴影(2,4)｜本回合计划：%s" % " ｜ ".join(parts))
	print("CHAIN2|结算|本回合玩家方阵亡：%d ⇒ %d（本回合多收 %d 个）" % [pdead0, pdead1, pdead1 - pdead0])