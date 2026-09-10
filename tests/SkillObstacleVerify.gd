extends Node
## 技能 × 障碍物 规则验证（两条互补）：
##   ① 主动攻击障碍物 → 只扣耐久，**不触发英雄技能**；
##   ② 技能对敌人生效时**波及到**的障碍物 → 掉 1 点耐久。
## T1 长剑剑气穿过敌人后，身后的障碍 -1 耐久（本次报的 bug）；
## T2 剑气不会被障碍拦住：障碍后面的敌人照常被穿到；
## T3 规则①：长剑主动打障碍 → 障碍 -1，但直线后面的敌人不掉血（技能没被触发）；
## T4 白游侠散射 / 超新星击穿：目标相邻的障碍 -1；
## T5 红帽扑街自爆：相邻障碍 -1；
## T6 烛火移动烧相邻障碍仍然 -1（回归：既有规则没被改坏）；
## T7 障碍耐久耗尽即消失（3 点打光）。
## 运行：godot --headless --scene res://tests/SkillObstacleVerify.tscn
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
	battle.gold_left.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func dur(c: Vector2i) -> int:
	return battle.obstacles.get(c, 0)

func _run() -> void:
	# ---- T1/T2: 长剑剑气：扫过的障碍 -1，且不被障碍挡住 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	# 直线方向：以攻方为起点、目标在其后方同一轴向（这里取竖直方向 (2,5)->(2,3)）
	var sw := spawn("hero_18", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	var victim := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 4))
	var behind := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	battle.obstacles[Vector2i(2, 3)] = 3   # 目标死后的直线中间放一面墙
	var wall0 := dur(Vector2i(2, 3))
	var behind_hp0 := behind.hp
	battle._pierce_line(sw, victim.cell)
	var wall_after := dur(Vector2i(2, 3))
	var t1: bool = wall_after == wall0 - 1
	print("T1 剑气波及障碍: 障碍耐久 %d->%d => %s" % [wall0, wall_after, "PASS" if t1 else "FAIL"])
	var t2: bool = behind.hp < behind_hp0
	print("T2 剑气不被障碍拦住: 墙后敌人HP %d->%d => %s" % [behind_hp0, behind.hp, "PASS" if t2 else "FAIL"])

	# ---- T3: 规则① 主动打障碍不触发技能 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var sw2 := spawn("hero_18", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	var behind2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	battle.obstacles[Vector2i(2, 4)] = 3   # 直接攻击它
	var hp_before := behind2.hp
	battle._do_attack_obstacle(sw2, Vector2i(2, 4))
	for i in 40:
		await battle.get_tree().process_frame
	var wall_hit: bool = dur(Vector2i(2, 4)) == 2
	var t3: bool = wall_hit and behind2.hp == hp_before
	print("T3 打障碍不触发技能: 障碍耐久=%d 墙后敌人HP %d->%d（不应掉血） => %s"
			% [dur(Vector2i(2, 4)), hp_before, behind2.hp, "PASS" if t3 else "FAIL"])

	# ---- T4: 白游侠散射 / 超新星击穿：目标相邻障碍 -1 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var ranger := spawn("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	var tgt := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 4))
	var side := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 4))   # 目标相邻敌人（散射对象）
	battle.obstacles[Vector2i(2, 3)] = 3   # 目标相邻的另一格放墙
	var w4 := dur(Vector2i(2, 3))
	battle._hero(ranger).on_attack(tgt)
	var t4: bool = dur(Vector2i(2, 3)) == w4 - 1 and side.hp < side.max_hp
	print("T4 散射波及相邻障碍: 障碍耐久 %d->%d 相邻敌人掉血=%s => %s"
			% [w4, dur(Vector2i(2, 3)), str(side.hp < side.max_hp), "PASS" if t4 else "FAIL"])

	var nova := spawn("hero_21", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	battle.obstacles[Vector2i(1, 4)] = 3
	var w4b := dur(Vector2i(1, 4))
	battle._hero(nova).on_attack(tgt)
	var t4b: bool = dur(Vector2i(1, 4)) == w4b - 1
	print("T4b 超新星击穿波及相邻障碍: 障碍耐久 %d->%d => %s" % [w4b, dur(Vector2i(1, 4)), "PASS" if t4b else "FAIL"])

	# ---- T5: 红帽扑街自爆波及相邻障碍 ----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var red := spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	battle.obstacles[Vector2i(2, 4)] = 3
	var w5 := dur(Vector2i(2, 4))
	battle._hero(red).on_died()
	var t5: bool = dur(Vector2i(2, 4)) == w5 - 1
	print("T5 红帽自爆波及相邻障碍: 障碍耐久 %d->%d => %s" % [w5, dur(Vector2i(2, 4)), "PASS" if t5 else "FAIL"])

	# ---- T6: 烛火移动烧相邻障碍（回归）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var candle := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	battle.obstacles[Vector2i(2, 4)] = 3
	var w6 := dur(Vector2i(2, 4))
	battle._hero(candle).on_move()
	var t6: bool = dur(Vector2i(2, 4)) == w6 - 1
	print("T6 烛火烧相邻障碍: 障碍耐久 %d->%d => %s" % [w6, dur(Vector2i(2, 4)), "PASS" if t6 else "FAIL"])

	# ---- T7: 障碍耐久打光即消失（用烛火灼烧，走已有机制，便于在改动前后对比）----
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var candle2 := spawn("hero_17", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	battle.obstacles[Vector2i(2, 4)] = 1   # 只剩 1 点耐久
	battle._hero(candle2).on_move()
	var t7: bool = not battle.obstacles.has(Vector2i(2, 4))
	print("T7 耐久耗尽即消失: 盘面还有该障碍=%s => %s" % [str(battle.obstacles.has(Vector2i(2, 4))), "PASS" if t7 else "FAIL"])

	var ok := t1 and t2 and t3 and t4 and t4b and t5 and t6 and t7
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
