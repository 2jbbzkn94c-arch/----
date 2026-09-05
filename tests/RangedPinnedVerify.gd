extends Node
## 远程被贴身判定验证：
## 被障碍物隔断的攻击不算"被贴身"；真正的贴脸(相邻且视线通畅)才算。
## 运行：godot --headless --scene res://tests/RangedPinnedVerify.tscn
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
	# T1：远程真贴脸(距1无障) -> 算被贴身（rangedAdj true, 射程降1）
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var r1 := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 4))   # 火枪手(远程)
	r1.refresh_stats()
	var near := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 3))   # 相邻(距1)
	battle._sync_ranged_adjacent()
	print("  [DBG] dist=", battle.grid.distance(r1.cell, near.cell),
		" blocked=", battle._attack_path_blocked(r1.cell, near.cell),
		" has_adj=", battle._has_enemy_adjacent(r1),
		" atk_type=", r1.attack_type, " RANGED=", DataRegistry.AttackType.RANGED,
		" baseRange=", r1.attack_range)
	print("T1 真贴脸算贴身: dist=", battle.grid.distance(r1.cell, near.cell),
		" rangedAdj=", r1.ranged_adjacent, " effRange=", battle._effective_attack_range(r1),
		" => %s" % ["PASS" if r1.ranged_adjacent and battle._effective_attack_range(r1) == 1 else "FAIL"])

	# T2：远程旁是障碍物，敌人在射程内但被障碍挡住(距2, blocked) -> 不算被贴身
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var r2 := spawn("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 4))
	r2.refresh_stats()
	battle.obstacles[Vector2i(4, 4)] = 30   # 中间障碍
	var far := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 4))   # 距2，隔障碍
	battle._sync_ranged_adjacent()
	print("T2 隔障碍不贴身: dist=", battle.grid.distance(r2.cell, far.cell),
		" blocked=", battle._attack_path_blocked(r2.cell, far.cell),
		" rangedAdj=", r2.ranged_adjacent, " effRange=", battle._effective_attack_range(r2),
		" => %s" % ["PASS" if not r2.ranged_adjacent and battle._effective_attack_range(r2) > 1 else "FAIL"])

	get_tree().quit()
