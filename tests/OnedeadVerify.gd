extends Node
## 1血逃不掉敌人是否进攻 验证：
## 敌人只剩1血、逃的位置仍会被打（逃不掉）、且能攻击玩家时，应选择攻击换血而非逃跑。
## 运行：godot --headless --scene res://tests/OnedeadVerify.tscn
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

func _run() -> void:
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	# 敌方近战 1 血、高攻，能贴脸打玩家；玩家远程射程覆盖敌方所有可达格 -> 敌方逃不掉
	var foe := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	foe.hp = 1; foe.max_hp = 1
	foe.atk = 6   # 打玩家能大量换血（甚至击杀）
	foe.refresh_stats()
	var pl := spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	pl.attack_range = 5   # 覆盖敌方所有可达格 -> 逃不掉
	pl.atk = 3
	pl.hp = 8; pl.max_hp = 8   # 敌方高攻能打掉大半
	pl.refresh_stats()

	var descs: Array = []
	var occ := {}
	for i in battle.units.size():
		var u: Unit = battle.units[i]
		descs.append(build_desc(u))
		occ[u.cell] = i
	var ai := BattleAI.new(battle.grid)
	ai.difficulty = 0   # 难度0也有抖动？用2最纯最优
	ai.difficulty = 2
	var sim := ai.build_state(descs, occ)
	var foe_idx := -1
	for i in sim.units.size():
		if sim.units[i].fn == DataRegistry.Faction.ENEMY:
			foe_idx = i
	var min_esc := ai._min_escape_incoming(sim, sim.units[foe_idx])
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var attacks := 0
	for st in plan:
		if st["action"].has("atk") and int(st["action"]["atk"]) >= 0:
			attacks += 1
	# 调试：手动构造攻击/逃跑两终态，比较 _evaluate 得分
	var player_idx := -1
	for i in sim.units.size():
		if sim.units[i].fn == DataRegistry.Faction.PLAYER:
			player_idx = i
	var sim_att = sim.clone()
	ai._apply(sim_att, foe_idx, { "atk": player_idx, "move": null })
	var sc_att: float = ai._evaluate(sim_att)
	var sim_esc = sim.clone()
	ai._apply(sim_esc, foe_idx, { "move": Vector2i(5, 9), "atk": -1 })
	var sc_esc: float = ai._evaluate(sim_esc)
	print("  [DBG] attack_score=%.2f escape_score=%.2f (attacked=%s esc_attacked=%s)" % [sc_att, sc_esc, str(sim_att.units[foe_idx].attacked), str(sim_esc.units[foe_idx].attacked)])
	print("T1 1血逃不掉应攻击: min_esc=%.1f 攻击次数=%d => %s" % [min_esc, attacks, "PASS" if attacks >= 1 else "FAIL"])
	print("  plan=", plan)
	get_tree().quit()
