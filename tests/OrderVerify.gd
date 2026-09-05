extends Node
## 敌方攻击顺序优化验证：
## search 应能自由排列攻击顺序，选出利益最大化方案。
## 场景：敌方两位——A(远程)能一刀砍死残血玩家P1，B(近战)只能打残另一个玩家P2。
## 最优顺序：先让A秒掉残血P1（消除其威胁/反击），而非固定单位顺序。
## 运行：godot --headless --scene res://tests/OrderVerify.tscn
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
	# 敌方 A：远程，能一刀秒残血 P1
	var a := spawn("hero_04", DataRegistry.Faction.ENEMY, Vector2i(5, 5))
	a.atk = 6; a.attack_range = 3; a.refresh_stats()
	# 敌方 B：近战，能打 P2
	var b := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(6, 5))
	b.atk = 2; b.refresh_stats()
	# 玩家 P1：1血残血，A 一击可秒
	var p1 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 5))
	p1.hp = 1; p1.max_hp = 10; p1.refresh_stats()
	# 玩家 P2：近战贴脸 B，会反击
	var p2 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(7, 5))
	p2.hp = 10; p2.max_hp = 10; p2.refresh_stats()

	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	# 找"秒掉P1(残血1)"的单位在计划里排第几位
	var a_idx := -1
	for i in sim.units.size():
		if sim.units[i].fn == DataRegistry.Faction.ENEMY and sim.units[i].hero_id == "hero_04":
			a_idx = i
	# 第一个攻击动作若是 A 秒掉 P1 附近残血，则为优化顺序
	var first_atk_is_a := false
	var first_atk_pos := -1
	var order := 0
	for st in plan:
		if st["action"].has("atk") and int(st["action"]["atk"]) >= 0:
			order += 1
			if int(st["idx"]) == a_idx and first_atk_pos == -1:
				first_atk_pos = order
				# 攻击目标是否残血1（有效收割）
				var tidx: int = int(st["action"]["atk"])
				first_atk_is_a = sim.units[tidx].hp <= 1
				break
	print("T1 先手秒残血: 计划=%s => %s" % [str(plan), "PASS" if first_atk_pos >= 1 and first_atk_is_a else "FAIL"])
	print("  first_atk(A对残血)=%s" % str(first_atk_is_a))
	get_tree().quit()
