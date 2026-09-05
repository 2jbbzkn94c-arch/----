extends Node
## 玩家反应前瞻验证：预测"玩家下一步能反制敌方"的威胁值。
## 玩家贴脸高攻能击杀敌方 -> 反制风险更负（对敌方不利）；敌方远离 -> 接近0。
## 运行：godot --headless --scene res://tests/PlayerLookaheadVerify.tscn
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

func _make_sim() -> Dictionary:
	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	return { "descs": descs, "occ": occ }

static func _run_test(ai: BattleAI, descs: Array, occ: Dictionary) -> float:
	var sim = ai.build_state(descs, occ)
	return ai._player_reaction_threat(sim)

func _run() -> void:
	# 场景A：玩家近战高攻贴脸敌方，能一击击杀 -> 反制风险高（更负）
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var pl := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	pl.atk = 10; pl.hp = 20; pl.max_hp = 20; pl.refresh_stats()
	var foe := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	foe.hp = 5; foe.max_hp = 20; foe.refresh_stats()   # 低血，玩家可击杀
	var dA = _make_sim()
	var ai := BattleAI.new(battle.grid); ai.difficulty = 2
	var simA = ai.build_state(dA["descs"], dA["occ"])
	for i in simA.units.size():
		print("  [A] u", i, " fn=", simA.units[i].fn, " cell=", simA.units[i].cell, " hp=", simA.units[i].hp)
	var threatA := _run_test(ai, dA["descs"], dA["occ"])
	print("  [DBG] A descs size=", dA["descs"].size())

	# 场景B：敌方远离玩家（玩家打不到）-> 反制风险接近0
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var pl2 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	pl2.atk = 10; pl2.hp = 20; pl2.max_hp = 20; pl2.refresh_stats()
	var foe2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(0, 1))
	foe2.hp = 5; foe2.max_hp = 20; foe2.refresh_stats()   # 远处打不到
	var dB = _make_sim()
	var simB = ai.build_state(dB["descs"], dB["occ"])
	for i in simB.units.size():
		print("  [B] u", i, " fn=", simB.units[i].fn, " cell=", simB.units[i].cell, " hp=", simB.units[i].hp)
	var pb = simB.units[0]
	var reachB = ai._move_cells(simB, pb)
	print("  [B] player move cells=", reachB.keys())
	print("  [B] player atk_range=", pb.atk_range, " atk_type=", pb.atk_type, " move=", pb.move)
	var threatB := _run_test(ai, dB["descs"], dB["occ"])

	print("T1 玩家反制前瞻: 贴脸威胁=%.2f 远离威胁=%.2f => %s" % [threatA, threatB, "PASS" if threatA < threatB and threatB >= -0.01 else "FAIL"])
	get_tree().quit()
