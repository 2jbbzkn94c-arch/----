extends Node
## 烛火移动技 × 锤头鲨成长 的规则验证：
## T1 烛火落点只相邻障碍（无相邻敌人）：烧障碍、不掉任何人血 → 锤头鲨不得 +1 攻；
## T2 烛火落点相邻敌人：灼烧造成伤害 → 同队锤头鲨 +1 攻（每条伤害只算一次）；
## T3 烛火落点同时相邻敌人与障碍：仍是"敌人受一次伤害" → 锤头鲨只 +1（不得因烧障碍多算）；
## T4 灼烧伤害被圣盾挡下（敌人实际掉 0 血）：不算"受到伤害" → 锤头鲨不得 +1。
## 运行：godot --headless --scene res://tests/CandleSharkVerify.tscn
var battle: Battle
var _dmg_log: Array = []   # 收到的每次 damaged 事件：[受击者, 伤害, 是否反击]

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
	battle.gold_left.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED
	_dmg_log = []

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	var u := battle._spawn_unit(hid, f, c)
	u.damaged.connect(func(who: Unit, amt: int): _dmg_log.append([who.display_name, amt, who._was_counter_damage]))
	return u

# 模拟"烛火走到某格后结算移动技"（与 _finish_move 里的触发点同口径）
func move_to_and_settle(u: Unit, cell: Vector2i) -> void:
	battle.occupancy.erase(u.cell)
	u.cell = cell
	battle.occupancy[cell] = u
	battle._finish_move(u, false)

func _run() -> void:
	# ---- T1: 只相邻障碍，无相邻敌人：烧障碍但不掉血 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var shark := spawn("hero_37", DataRegistry.Faction.PLAYER, Vector2i(0, 6))
	var candle := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 1))   # 远处敌人，不与落点相邻
	battle.obstacles[Vector2i(4, 6)] = 3   # 落点 (3,6) 的相邻障碍
	var atk0 := shark.atk_buff
	move_to_and_settle(candle, Vector2i(3, 6))
	var burned: bool = battle.obstacles.get(Vector2i(4, 6), 3) == 2
	var t1: bool = burned and shark.atk_buff == atk0 and _dmg_log.is_empty()
	print("T1 只烧障碍不加攻: 障碍3->%s 锤头鲨atk_buff=%d(原%d) 受伤事件=%d => %s"
			% [str(battle.obstacles.get(Vector2i(4, 6), 0)), shark.atk_buff, atk0, _dmg_log.size(), "PASS" if t1 else "FAIL"])
	if not t1:
		print("   >> 本次受伤事件明细: ", _dmg_log)

	# ---- T2: 落点相邻敌人：灼烧 -> 锤头鲨 +1 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var shark2 := spawn("hero_37", DataRegistry.Faction.PLAYER, Vector2i(0, 6))
	var candle2 := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var victim := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))   # 落点 (3,6) 的相邻敌人
	var hp0 := victim.hp
	move_to_and_settle(candle2, Vector2i(3, 6))
	var t2: bool = victim.hp == hp0 - candle2.effective_atk() and shark2.atk_buff == 1 and _dmg_log.size() == 1
	print("T2 灼烧命中加1攻: 敌人HP %d->%d 锤头鲨atk_buff=%d 受伤事件=%d => %s"
			% [hp0, victim.hp, shark2.atk_buff, _dmg_log.size(), "PASS" if t2 else "FAIL"])

	# ---- T3: 同时相邻敌人 + 障碍：只算一次伤害 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var shark3 := spawn("hero_37", DataRegistry.Faction.PLAYER, Vector2i(0, 6))
	var candle3 := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	battle.obstacles[Vector2i(3, 5)] = 3   # 落点 (3,6) 的另一个相邻格放障碍
	battle.obstacles[Vector2i(2, 5)] = 3
	move_to_and_settle(candle3, Vector2i(3, 6))
	var t3: bool = shark3.atk_buff == 1 and _dmg_log.size() == 1
	print("T3 敌人+障碍只加1攻: 锤头鲨atk_buff=%d 受伤事件=%d => %s" % [shark3.atk_buff, _dmg_log.size(), "PASS" if t3 else "FAIL"])

	# ---- T4: 灼烧被圣盾挡下（实际掉 0 血）：不算受伤 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var shark4 := spawn("hero_37", DataRegistry.Faction.PLAYER, Vector2i(0, 6))
	var candle4 := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	var guarded := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	guarded.add_status(StatusDB.SHIELD)
	var ghp0 := guarded.hp
	move_to_and_settle(candle4, Vector2i(3, 6))
	var t4: bool = guarded.hp == ghp0 and shark4.atk_buff == 0 and _dmg_log.is_empty()
	print("T4 被圣盾挡下不算受伤: 敌人HP %d->%d 锤头鲨atk_buff=%d 受伤事件=%d => %s"
			% [ghp0, guarded.hp, shark4.atk_buff, _dmg_log.size(), "PASS" if t4 else "FAIL"])

	var ok := t1 and t2 and t3 and t4
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
