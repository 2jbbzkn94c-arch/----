extends Node
## 【2026-10-02·一次性探针·只读·用户「攻击障碍物也会让攻击buff消失」→「**我是说需要消失**」】
##
## 口径（用户定）：**敲障碍也算一次"攻击结算"** ⇒ 「一次性攻击道具 +2」（`Unit.atk_use_buff`，
##   "下一次攻击"用掉）**必须被消耗**，与打单位/反击同口径。
##   探针把"加攻击力"的几种临时增益逐个放到"敲障碍"这条真链路上过一遍，看谁掉谁不掉：
##     · `atk_use_buff`（拾取攻击道具 +2）—— **该掉**（本次改动）
##     · `atk_buff`（回合增益：烈焰祭司/锤头鲨/负墟那类）—— 不该掉（那是"整回合"的增益，回合末才清）
##     · `sun_bonus`（太阳斩登场 +3）—— 不该掉（它是**英雄特技**的账，而"主动敲障碍不触发任何英雄特技"）
##     · `ramble_bonus`（冲锋加成）—— 不该掉（同样属于英雄特技）
##     · `move_use_buff`（移动道具）—— 不该掉（那是"下一次移动"的账）
##     · 对照：真打一个单位 ⇒ `atk_use_buff` 该掉
##   另加一条**顺序**校验（伐木工）：耐久伤害照常吃到 +2（`有效攻击力 + 99`），**用完才清**。
##
## 输出：BUF|… / BUF|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _arm("A_攻击道具buff·直接敲障碍", "obstacle_direct", "atk_use_buff", "hero_18", 2, true)
	await _arm("B_攻击道具buff·玩家提交敲障碍", "obstacle_submit", "atk_use_buff", "hero_18", 2, true)
	await _arm("C_回合增益atk_buff·敲障碍", "obstacle_direct", "atk_buff", "hero_18", 1, false)
	await _arm("D_太阳斩登场+3·敲障碍", "obstacle_direct", "sun_bonus", "hero_29", 3, false)
	await _arm("E_冲锋加成·敲障碍", "obstacle_direct", "ramble_bonus", "hero_24", 2, false)
	await _arm("F_移动道具buff·敲障碍", "obstacle_direct", "move_use_buff", "hero_18", 1, false)
	await _arm("G_对照·真打单位（该掉）", "attack_unit", "atk_use_buff", "hero_18", 2, true)
	await _arm("H_伐木工敲障碍·先吃+2再清", "obstacle_direct", "atk_use_buff", "hero_01", 2, true, 300)
	print("BUF|END")
	get_tree().quit(0)

## expect_drop = 这一项**该不该**被敲障碍/攻击清掉；obs_hp > 0 时用那块厚的障碍量耐久伤害
func _arm(tag: String, mode: String, field: String, hid: String, amount: int,
		expect_drop: bool, obs_hp: int = 9) -> void:
	await _rebuild()
	var u = _spawn(hid, DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	var foe = _spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(2, 2))   # 对照臂的靶子（33 血，打不死）
	var obs := Vector2i(2, 4)
	battle.obstacles[obs] = obs_hp
	if u == null:
		print("BUF|%s|上不了人（跳过）" % tag)
		return
	# A/B/G/H 走"拾取攻击道具"那条真链路；其余直接给对应字段（那些增益本来就不是从道具来的）
	if field == "atk_use_buff":
		battle.buff_items[u.cell] = "atk"
		battle._pickup_buff_at_cell(u)
	else:
		u.set(field, amount)
	u.moved_this_turn = false
	u.attacked_this_turn = false
	u.refresh_stats()
	for i in 3:
		await get_tree().process_frame
	var v0 = int(u.get(field))
	var eatk0: int = u.effective_atk()
	var yellow0: bool = u.atk_is_buffed()
	var dura0: int = int(battle.obstacles.get(obs, -1))
	match mode:
		"obstacle_direct":
			battle._do_attack_obstacle(u, obs)
		"obstacle_submit":
			battle.submit_attack_obstacle(battle.units.find(u), obs)
		"attack_unit":
			battle._do_attack(u, foe, false)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1300:
		await get_tree().process_frame
	var v1 = int(u.get(field))
	var eatk1: int = u.effective_atk()
	var yellow1: bool = u.atk_is_buffed()
	var dura1: int = int(battle.obstacles.get(obs, -1))
	var dealt: int = (33 - int(foe.hp)) if (foe != null and is_instance_valid(foe)) else -1
	var dropped: bool = v1 == 0
	var ok := (dropped == expect_drop) and v0 > 0
	print("BUF|%s|%s %d→%d（期望%s）｜攻 %d→%d｜标黄 %s→%s｜障碍耐久 %d→%d（这一下扣了 %s）｜真打单位伤害=%d ⇒ %s" % [
		tag, field, v0, v1, ("掉" if expect_drop else "不掉"), eatk0, eatk1, str(yellow0), str(yellow1),
		dura0, dura1, str(dura0 - dura1) if dura1 >= 0 else "拆掉了",
		dealt, ("**PASS**" if ok else "**FAIL**")])

func _rebuild() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.buff_owner.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_PLAYER
	battle.state = battle.State.PLAYER_INPUT

func _spawn(hid: String, fn, cell: Vector2i):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
	return u
