extends Node
## 敌人 AI「逃不掉则攻击」验证：
## 当敌方单位无论怎么移动都会被玩家攻击到（逃不掉）时，AI 应选择攻击而非无意义逃跑。
## 运行：godot --headless --scene res://tests/TrapVerify.tscn
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
	# 敌方近战英雄被玩家远程(射程覆盖全场)盯上：它无论怎么移动都逃不出玩家攻击范围
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var enemy := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	enemy.atk = 3
	enemy.hp = 20; enemy.max_hp = 20
	enemy.refresh_stats()
	# 玩家远程单位：射程大、攻高，紧挨敌方（敌方贴脸能打到它）
	var pl := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	pl.attack_range = 5   # 覆盖敌方所有可达格 -> 逃不掉
	pl.atk = 3
	pl.hp = 30; pl.max_hp = 30
	pl.refresh_stats()

	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	var enemy_idx := -1
	if sim.units[0].fn == DataRegistry.Faction.ENEMY:
		enemy_idx = 0
	else:
		enemy_idx = 1
	# 验证"逃不掉"
	var min_esc := ai._min_escape_incoming(sim, sim.units[enemy_idx])
	var trapped := min_esc > 0.0
	# 搜索计划
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var attacks := 0
	for st in plan:
		if st["action"].has("atk") and int(st["action"]["atk"]) >= 0:
			attacks += 1
	print("T1 逃不掉则攻击: min_escape=%.1f trapped=%s 攻击次数=%d => %s" % [min_esc, str(trapped), attacks, str("PASS" if trapped and attacks >= 1 else "FAIL")])

	get_tree().quit()
