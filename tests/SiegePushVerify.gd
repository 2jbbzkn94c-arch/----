extends Node
## 敌方参战驱动验证：战斗爆发时，躲在角落"打不到玩家"的敌方英雄应被惩罚(游荡)，
## 而推进到能攻击玩家的位置应得高分——驱动它们加入战斗，而非边角游荡。
## 运行：godot --headless --scene res://tests/SiegePushVerify.tscn
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
	return BattleSnapshot.unit_desc(battle, u)

func _build_sim():
	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid); ai.difficulty = 2
	return ai.build_state(descs, occ)

func _run() -> void:
	# 战斗爆发：一个敌方已受伤；另一个敌方英雄在"边角"(远处打不到玩家)
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var wounded := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	wounded.hp = 5; wounded.max_hp = 20; wounded.refresh_stats()   # 受伤 -> 爆发
	var corner := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(0, 1))   # 边角，打不到玩家
	var pl := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(6, 6))
	pl.hp = 20; pl.max_hp = 20; pl.refresh_stats()
	var ai := BattleAI.new(battle.grid); ai.difficulty = 2
	var sim_corner = _build_sim()
	var sc_corner: float = ai._siege_bonus(sim_corner)

	# 对照：同一敌方英雄推进到能打玩家(射程内)
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var wounded2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	wounded2.hp = 5; wounded2.max_hp = 20; wounded2.refresh_stats()
	var close := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(5, 6))   # 贴近能打玩家
	var pl2 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(6, 6))
	pl2.hp = 20; pl2.max_hp = 20; pl2.refresh_stats()
	var ai2 := BattleAI.new(battle.grid); ai2.difficulty = 2
	var sim_close = _build_sim()
	var sc_close: float = ai2._siege_bonus(sim_close)

	print("T1 边角游荡被罚/参战得高分: 边角=%.2f 射程内=%.2f => %s" % [sc_corner, sc_close, "PASS" if sc_close > sc_corner else "FAIL"])
	get_tree().quit()
