extends Node
## 血锁「只能打直线」AI 侧验证：
## 敌方血锁在模拟（_in_range / _valid_targets）里，直线上的玩家目标可选、非直线不可选。
## 运行：godot --headless --scene res://tests/BloodAiVerify.tscn
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

func _run() -> void:
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	# 敌方血锁（hero_41），射程已含 +2（默认 attack_range，build 时 hero_41 射程+2）
	var blood := spawn("hero_41", DataRegistry.Faction.ENEMY, Vector2i(3, 8))
	# 直线上的玩家目标（同轴向：同列）
	var line_t := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 5))
	# 非直线玩家目标（斜向偏离）
	var off_t := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(5, 8))

	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	var blood_idx := -1
	var line_idx := -1
	var off_idx := -1
	for i in sim.units.size():
		if sim.units[i].hero_id == "hero_41":
			blood_idx = i
		elif sim.units[i].fn == DataRegistry.Faction.PLAYER and sim.units[i].cell == Vector2i(3, 5):
			line_idx = i
		elif sim.units[i].fn == DataRegistry.Faction.PLAYER and sim.units[i].cell == Vector2i(5, 8):
			off_idx = i
	var targets: Array = ai._valid_targets(sim, sim.units[blood_idx], sim.units[blood_idx].cell)
	var has_line := targets.has(line_idx)
	var has_off := targets.has(off_idx)
	print("T1 AI血锁只打直线: 直线=%s 非直线=%s => %s" % [has_line, has_off, "PASS" if has_line and not has_off else "FAIL"])
	print("  targets=", targets)
	get_tree().quit()
