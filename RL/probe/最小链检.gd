extends Node
## 【2026-09-29 晚·最小探针】用户口径的"2 选 1"盘面：**已经上了小阴影**（不是超新星），
##   玩家还剩 3 人（嬉皮死神 11 / 血锁 11 / 负墟 1），玩家已死 1 名。
##   只做一件事：跑**一次**噩梦搜索 → 按计划真实顺序重放 → 打印每一刀的**伤害/击杀**与**本回合玩家方阵亡数**。

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
	_s("hero_18", DataRegistry.Faction.ENEMY, Vector2i(2, 6), 7)    # 长剑
	_s("hero_40", DataRegistry.Faction.ENEMY, Vector2i(1, 5), 11)   # 红帽
	_s("hero_15", DataRegistry.Faction.ENEMY, Vector2i(2, 4), 18)   # 小阴影（这次替补上的是它）
	_s("hero_30", DataRegistry.Faction.PLAYER, Vector2i(1, 3), 11)  # 嬉皮死神
	_s("hero_41", DataRegistry.Faction.PLAYER, Vector2i(3, 3), 11)  # 血锁
	_s("hero_44", DataRegistry.Faction.PLAYER, Vector2i(2, 5), 1)   # 负墟（1 血）
	for x in [0, 4]:
		for y in [3, 4]:
			battle.obstacles[Vector2i(x, y)] = 2
	battle.player_dead = 1
	battle.enemy_dead = 2
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var ai = battle._make_battle_ai()
	if ai == null:
		print("MIN|拿不到 AI")
		get_tree().quit(0)
		return
	ai.difficulty = 3
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var p0 := 0
	for u in sim.units:
		if u != null and not u.alive and u.fn != DataRegistry.Faction.ENEMY:
			p0 += 1
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	print("MIN|搜索完成 %dms｜步数=%d" % [Time.get_ticks_msec() - t0, plan.size()])
	var parts: Array = []
	for st in plan:
		var a: Dictionary = st["action"]
		var ui := int(st["idx"])
		var un := String(sim.units[ui].name) if ui >= 0 and ui < sim.units.size() else "?"
		var atk := int(a.get("atk", -1))
		if atk < 0:
			if atk == -2:
				parts.append("%s 敲障碍%s" % [un, str(a.get("atk_obs", "?"))])
			elif a.get("move", null) != null:
				parts.append("%s→%s（只走位）" % [un, str(a.get("move"))])
			continue
		if atk >= sim.units.size():
			continue
		var t = sim.units[atk]
		var hp0 := int(t.hp)
		var tn := String(t.name)
		ai._apply(sim, ui, a)
		var dead: bool = not bool(t.alive)
		parts.append("%s 打 %s：%d→%d%s" % [un, tn, hp0, (0 if dead else int(t.hp)), ("　**击杀**" if dead else "")])
	print("MIN|计划：%s" % " ｜ ".join(parts))
	var p1 := 0
	for u2 in sim.units:
		if u2 != null and not u2.alive and u2.fn != DataRegistry.Faction.ENEMY:
			p1 += 1
	print("MIN|结算|玩家方阵亡 %d ⇒ %d（本回合 +%d）%s" % [p0, p1, p1 - p0,
		("　⇒ 到判负线 = 直接判负 ✓" if p1 >= 3 else "")])
	print("MIN|END")
	get_tree().quit(0)

func _s(hid: String, fn: int, cell: Vector2i, hp: int) -> void:
	var u := battle._spawn_unit(hid, fn, cell)
	if u != null and hp > 0:
		u.hp = hp
