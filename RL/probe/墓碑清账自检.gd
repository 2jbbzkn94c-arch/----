extends Node
## 【2026-09-29 一次性探针·只读】**墓碑清账**自检 —— 用户口径：
##   「**哪方的墓碑在哪方回合结束就消失**」（取代 2026-09-28 那条"只在敌方回合结束把两边一起清"
##   + "敌方碑补完位即时清"）。
##
## 步骤（全在真 Battle 上跑，不改生产代码）：
##   ① 摆盘：我方 hero_01 + 敌方 hero_26，并给**两边各立一座测试碑**（直接写 `graves`，格式同 `_on_unit_died`）；
##   ② `await _end_side(SIDE_PLAYER)`（= 玩家点「结束回合」那条链路）⇒ 期望：**我方碑清空、敌方碑还留着**；
##   ③ `_begin_side(SIDE_ENEMY)` 让敌方回合自己跑完（`_run_enemy_turn()` 是 `call_deferred` 起的，
##      所以这里轮询状态等它收敛）⇒ 期望：**敌方碑也清空**。
##
## 输出：`GRAVE|...` 行，末尾 `GRAVE|END`。难度取**简单(0)**：本探针只关心回合末清账，不需要噩梦搜索。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false
	GameState.pick_deck_in_battle = true
	GameState.ai_difficulty = 0
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(99007)
	get_tree().root.add_child(_b)
	if not await _wait_state([Battle.State.DECK_PICK], 15.0):
		print("GRAVE|FATAL|no_deck_pick|state=%d" % int(_b.state))
		await _done()
		return
	_b._start_with_player_deck(["hero_01", "hero_06", "hero_12"])
	await _frames(8)
	_clear()
	_spawn("hero_01", DataRegistry.Faction.PLAYER, Vector2i(3, 4))
	_spawn("hero_26", DataRegistry.Faction.ENEMY, Vector2i(3, 1))
	_b.graves[Vector2i(2, 3)] = { "fn": DataRegistry.Faction.PLAYER, "hero": "hero_01" }
	_b.graves[Vector2i(4, 2)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_26" }
	print("GRAVE|①摆盘|%s" % _fmt())
	await _b._end_side(GameState.SIDE_PLAYER)
	print("GRAVE|②我方回合末（期望：我方碑清空 / 敌方碑还在）|%s" % _fmt())
	GameState.active_side = GameState.SIDE_ENEMY
	_b._begin_side(GameState.SIDE_ENEMY)
	if not await _wait_state([Battle.State.PLAYER_INPUT], 120.0):
		print("GRAVE|WARN|敌方回合没回到玩家输入（state=%d）" % int(_b.state))
	print("GRAVE|③敌方回合末（期望：敌方碑也清空）|%s" % _fmt())
	await _done()

func _fmt() -> String:
	var p: Array = []
	var e: Array = []
	for g in _b.graves.keys():
		var gd = _b.graves[g]
		var fn := int(gd.get("fn", -1)) if typeof(gd) == TYPE_DICTIONARY else -1
		if fn == DataRegistry.Faction.ENEMY:
			e.append(str(g))
		else:
			p.append(str(g))
	return "玩家碑=%d 座[%s]｜敌方碑=%d 座[%s]" % [p.size(), ", ".join(p), e.size(), ", ".join(e)]

func _clear() -> void:
	for u in _b.units:
		if is_instance_valid(u):
			u.queue_free()
	_b.units.clear()
	_b.occupancy.clear()
	_b.graves.clear()
	_b.obstacles.clear()
	_b.enemy_roster.clear()
	_b.player_roster.clear()
	_b.enemy_dead = 0
	_b.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i) -> void:
	var u := _b._spawn_unit(hid, faction, cell)
	if u == null:
		print("GRAVE|WARN|spawn_failed|%s" % hid)

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_state(states: Array, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if states.has(_b.state):
			return true
		await get_tree().process_frame
		t += 1.0 / 60.0
	return false

func _done() -> void:
	print("GRAVE|END")
	get_tree().quit(0)
