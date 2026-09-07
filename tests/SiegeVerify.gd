extends Node
## 战斗增援验证：敌方有人被攻击受伤时，_siege_bonus 应 >0 驱动其余英雄逼近参战；
## 未爆发战斗时为 0（不额外推进）。
## 运行：godot --headless --scene res://tests/SiegeVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func clear_all() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func build_desc(u: Unit) -> Dictionary:
	return {
		"fn": u.faction, "hero": u.hero_id, "cell": u.cell, "hp": u.hp, "max_hp": u.max_hp,
		"atk": u.atk, "eatk": u.effective_atk(), "move": u.move_range, "emove": u.effective_move(),
		"atk_range": u.attack_range, "atk_type": u.attack_type, "skills": u.skills, "name": u.display_name,
		"stunned": u.has_status("stun"), "silenced": u.has_status("silence"),
		"shield": u.has_status("shield"), "heavy": u.has_status("heavy"),
		"poisoned": u.has_status("poison"), "frozen": u.has_status("freeze"),
	}

func _make_sim():
	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	# 注意：血量要在 spawn 后再改，build_desc 时读取
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	return sim

func _run() -> void:
	# 场景A：未爆发战斗——敌方都满血、无相邻交战
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var far := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 6))
	far.hp = 20; far.max_hp = 20; far.refresh_stats()
	var pl := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(6, 6))
	pl.hp = 20; pl.max_hp = 20; pl.refresh_stats()
	var sim_no = _make_sim()
	var ai_no := BattleAI.new(battle.grid); ai_no.difficulty = 2
	var s1 := ai_no._siege_bonus(sim_no)

	# 场景B：战斗爆发——敌方有单位受伤（hp<max_hp）
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var wounded := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 6))
	wounded.hp = 5; wounded.max_hp = 20; wounded.refresh_stats()   # 受伤
	var far2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 6))
	far2.hp = 20; far2.max_hp = 20; far2.refresh_stats()
	var pl2 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(6, 6))
	pl2.hp = 20; pl2.max_hp = 20; pl2.refresh_stats()
	var sim_yes = _make_sim()
	var ai_yes := BattleAI.new(battle.grid); ai_yes.difficulty = 2
	for i in sim_yes.units.size():
		var su = sim_yes.units[i]
		print("  [DBG] sim u", i, " fn=", su.fn, " hp=", su.hp, " max=", su.max_hp)
	var s2 := ai_yes._siege_bonus(sim_yes)

	print("T1 战斗爆发增援: 未爆发=%.2f 受伤爆发=%.2f => %s" % [s1, s2, "PASS" if s1 <= 0.0 and s2 > 0.0 else "FAIL"])
	get_tree().quit()
