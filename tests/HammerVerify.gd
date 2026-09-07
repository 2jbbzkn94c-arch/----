extends Node
## 锤头鲨 AI 验证：
## 1) AI 模拟攻击玩家时，同阵营锤头鲨的攻击力应累积 +1（敌方受伤即触发）；
## 2) search 应将锤头鲨排在行动序列末尾（先队友攻击累积，锤头鲨后打）。
## 运行：godot --headless --scene res://tests/HammerVerify.tscn
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

func _run() -> void:
	# T1: AI 模拟里同阵营锤头鲨吃敌方受伤 buff
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var hammer := spawn("hero_37", DataRegistry.Faction.ENEMY, Vector2i(3, 6))
	var attacker := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	attacker.atk = 3
	attacker.refresh_stats()
	var player := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(5, 6))
	player.hp = 30; player.max_hp = 30; player.refresh_stats()
	# 构建 sim
	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append({
			"fn": u.faction, "hero": u.hero_id, "cell": u.cell, "hp": u.hp, "max_hp": u.max_hp,
			"atk": u.atk, "eatk": u.effective_atk(), "move": u.move_range, "emove": u.effective_move(),
			"atk_range": u.attack_range, "atk_type": u.attack_type, "skills": u.skills, "name": u.display_name,
			"stunned": u.has_status("stun"), "silenced": u.has_status("silence"),
			"shield": u.has_status("shield"), "heavy": u.has_status("heavy"),
			"poisoned": u.has_status("poison"), "frozen": u.has_status("freeze"),
		})
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	# attacker 攻击玩家
	var ham_idx := -1
	var atk_idx := -1
	var player_idx := -1
	for i in sim.units.size():
		if sim.units[i].hero_id == "hero_37":
			ham_idx = i
		elif sim.units[i].fn == DataRegistry.Faction.ENEMY and sim.units[i].hero_id != "hero_37":
			atk_idx = i
		elif sim.units[i].fn == DataRegistry.Faction.PLAYER:
			player_idx = i
	var ham_before: int = sim.units[ham_idx].eatk
	ai._apply(sim, atk_idx, { "atk": player_idx, "move": null })
	var ham_after: int = sim.units[ham_idx].eatk
	print("T1 锤头鲨模拟吃敌方受伤buff: %d->%d => %s" % [ham_before, ham_after, "PASS" if ham_after > ham_before else "FAIL"])

	# T2: search 排序把锤头鲨放末尾
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var hammer2 := spawn("hero_37", DataRegistry.Faction.ENEMY, Vector2i(3, 5))
	var mage := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 5))
	var pl := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(5, 5))
	pl.hp = 30; pl.max_hp = 30; pl.refresh_stats()
	var descs2: Array = []
	var occ2 := {}
	for i in battle.units.size():
		var u2: Unit = battle.units[i]
		descs2.append({
			"fn": u2.faction, "hero": u2.hero_id, "cell": u2.cell, "hp": u2.hp, "max_hp": u2.max_hp,
			"atk": u2.atk, "eatk": u2.effective_atk(), "move": u2.move_range, "emove": u2.effective_move(),
			"atk_range": u2.attack_range, "atk_type": u2.attack_type, "skills": u2.skills, "name": u2.display_name,
			"stunned": u2.has_status("stun"), "silenced": u2.has_status("silence"),
			"shield": u2.has_status("shield"), "heavy": u2.has_status("heavy"),
			"poisoned": u2.has_status("poison"), "frozen": u2.has_status("freeze"),
		})
		occ2[u2.cell] = i
	var ai2 := BattleAI.new(battle.grid)
	ai2.difficulty = 2
	var sim2 := ai2.build_state(descs2, occ2)
	var plan: Array = ai2.search(sim2, DataRegistry.Faction.ENEMY)
	# 找锤头鲨在计划中的位置与总攻击步
	var hammer_pos := -1
	var total_atk_steps := 0
	var step_i := 0
	for st in plan:
		if st["action"].has("atk") and int(st["action"]["atk"]) >= 0:
			if sim2.units[int(st["idx"])].hero_id == "hero_37":
				hammer_pos = total_atk_steps
			total_atk_steps += 1
		step_i += 1
	print("T2 锤头鲨排最后攻击: 攻击步=%d 锤头位置=%d => %s" % [total_atk_steps, hammer_pos, "PASS" if hammer_pos == -1 or hammer_pos >= total_atk_steps - 1 else "FAIL"])

	get_tree().quit()
