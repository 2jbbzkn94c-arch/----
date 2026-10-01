extends Node
## 【2026-10-01·一次性探针·只读·用户「怎么 AI 直接不顾自己被爆炸巨额伤害，也要打爆我的红帽」】
##   量三件事：
##     ① 打爆红帽之后，AI **自己掉多少血 / 死几个**（模拟里真打一遍）
##     ② AI 得到什么（击杀她 = 对面身价项消失 ≈ +26）
##     ③ 为什么它还是打：`REDCAP_BLAST_ALLY_W`（止损项）**只在「她下回合会死」时**才算，
##        而"我们主动打爆她"这条路上它一分都不罚 ⇒ 净账差多少。
##
## 盘面：玩家 红帽(hero_40)@(3,4) **4 血**（够一击打死）｜AI 影丸(hero_07)@(3,5)（贴身，**2 血**，会被 13 点炸死）
##   ＋ AI 塔盾(hero_11)@(0,1)（远处，不挨炸）｜另有 AI 一个满血单位做对照。
##   攻方 = 影丸（近战射程 1、攻 2）：它站在她旁边，这一刀打死她 ⇒ 自己吃 13、必死。
##
## 输出：RCB|CFG / RCB|打之前 / RCB|打之后 / RCB|账 / RCB|判定 / RCB|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
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
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(3, 4), 2)    # 玩家红帽（**2 血** ⇒ 影丸 2 攻正好打死 ⇒ 触发自爆）
	_spawn("hero_07", DataRegistry.Faction.ENEMY, Vector2i(3, 5), 2)     # AI 影丸（贴身、2 血 ⇒ 会被炸死）
	_spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 3), 33)    # AI 独脚龟（也贴身、33 血 ⇒ 只掉 13）
	_spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(0, 1), 40)    # AI 塔盾（远处，不挨炸）
	battle.player_dead = 0
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var her: Unit = null
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_40":
			her = u
	if her == null:
		print("RCB|拿不到红帽"); get_tree().quit(0); return
	print("RCB|CFG|红帽 血%d @%s ｜ 我方(贴着她): %s ｜ %s" % [
		int(her.hp), DataRegistry.cell_txt(her.cell), _mine_txt(), _her_neighbors()])
	# ---- 模拟侧：AI 打她一刀，看它自己掉多少 ----
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var before := {}
	for i in sim.units.size():
		var u = sim.units[i]
		if u != null and int(u.fn) == int(DataRegistry.Faction.ENEMY):
			before[String(u.hero_id)] = int(u.hp)
	var hi := -1
	var atk_i := -1
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null:
			continue
		if String(u.hero_id) == "hero_40":
			hi = i
		if String(u.hero_id) == "hero_07":
			atk_i = i
	print("RCB|打之前|%s ⇒ 模拟分 = %.2f" % [_mine_hp_txt(before), ai._evaluate(sim, true)])
	ai._apply(sim, atk_i, { "move": null, "atk": hi })
	var after := {}
	var dead := 0
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or int(u.fn) != int(DataRegistry.Faction.ENEMY):
			continue
		after[String(u.hero_id)] = int(u.hp) if bool(u.alive) else 0
		if not bool(u.alive):
			dead += 1
	print("RCB|打之后|红帽存活=%s ｜ 我方血：%s ｜ **我方阵亡 %d 个** ⇒ 模拟分 = %.2f" % [
		str(bool(sim.units[hi].alive)), _mine_hp_txt(after), dead, ai._evaluate(sim, true)])
	# 【逐项账用的第二份模拟】同一盘面重建一次，打同一刀，比较分项（避免"打之前"被覆盖）
	var sim2 = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var sim2_after = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	ai._apply(sim2_after, atk_i, { "move": null, "atk": hi })
	# ---- 那笔"止损"罚分现在值多少 ----
	var her_sim = sim.units[hi]
	var terms = ai._redcap_terms(sim)
	print("RCB|账|红帽那几项（关着的时候全 0）= %s" % str(terms))
	# 【逐项账】打之前/打之后的末态分项对比 ⇒ 一眼看出 +105 分是谁贡献的
	var bd_before: Dictionary = ai._eval_breakdown(sim2)
	var bd_after: Dictionary = ai._eval_breakdown(sim2_after)
	for k in bd_before.keys():
		var dl := float(bd_after.get(k, 0.0)) - float(bd_before[k])
		if absf(dl) >= 0.05:
			print("RCB|逐项|%s：%.1f → %.1f（Δ%+.1f）" % [String(k), float(bd_before[k]), float(bd_after.get(k, 0.0)), dl])
	var pen_now = 0.0
	var pen_scale = 0.0
	for i in sim.units.size():
		var v = sim.units[i]
		if v == null or not v.alive or int(v.fn) != int(DataRegistry.Faction.ENEMY):
			continue
		if battle.grid.distance(v.cell, her_sim.cell) != 1:
			continue
		pen_now += ai._unit_value(sim, v) / 20.0
		if 13.0 >= float(int(v.hp)):
			pen_now += 1.0
		pen_scale += ai._unit_value(sim, v) / 20.0 + (float(int(v.hp)) if 13.0 >= float(int(v.hp)) else 0.0)
	print("RCB|账|「止损」项现在= −W×%.1f（W=1 时 −%.1f）｜同一批人按「真会死就按身价算」= −W×%.1f ⇒ 两种口径差 %.1f 倍" % [
		pen_now, pen_now, pen_scale, (pen_scale / maxf(pen_now, 0.001))])
	print("RCB|判定|打爆她：我方死 %d 个、掉血 %s ⇒ 若这一刀的净账仍为正，就是评分在鼓励它" % [
		dead, _drop_txt(before, after)])
	print("RCB|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i, hp: int) -> Unit:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		u.hp = hp
	return u

func _mine_txt() -> String:
	var out: Array = []
	for u in battle.units:
		if is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			out.append("%s@%s血%d" % [String(u.display_name), DataRegistry.cell_txt(u.cell), int(u.hp)])
	return "、".join(out)

func _her_neighbors() -> String:
	var out: Array = []
	var her: Unit = null
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_40":
			her = u
	if her == null:
		return "—"
	for u in battle.units:
		if is_instance_valid(u) and u.alive and u != her and battle.grid.distance(u.cell, her.cell) == 1:
			out.append("%s(血%d)" % [String(u.display_name), int(u.hp)])
	return "相邻: " + ("、".join(out) if out.size() > 0 else "无")

func _mine_hp_txt(d: Dictionary) -> String:
	var out: Array = []
	for k in d.keys():
		out.append("%s=%d" % [String(k), int(d[k])])
	return " ｜ ".join(out)

func _drop_txt(before: Dictionary, after: Dictionary) -> String:
	var out: Array = []
	for k in before.keys():
		var d := int(before[k]) - int(after.get(k, 0))
		if d > 0:
			out.append("%s −%d" % [String(k), d])
	return "、".join(out)
