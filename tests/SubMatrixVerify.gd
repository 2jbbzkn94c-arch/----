extends Node
## 替补回归矩阵：三种模式 × 三个场景，一键验证。
## 模式：0=普通(单机) 1=竞技场 2=自由部署沙箱
## 场景：A=死1补1 B=死2补2 C=回合超时自动补
## 运行：godot --headless --scene res://tests/SubMatrixVerify.tscn
var battle: Battle
var fail_total := 0

func _ready() -> void:
	_run.call_deferred()

func _reset(mode: int) -> void:
	if battle != null and is_instance_valid(battle):
		for u in battle.units:
			if is_instance_valid(u):
				u.queue_free()
		battle.queue_free()
		await get_tree().process_frame
	GameState.reset_online()
	GameState.arena_mode = mode == 1
	GameState.no_death_limit = mode == 2
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	GameState.clear_placement()
	GameState.player_placement[Vector2i(2, 8)] = "hero_32"
	GameState.player_placement[Vector2i(4, 8)] = "hero_33"
	GameState.enemy_placement[Vector2i(1, 0)] = "hero_13"
	battle._place_units()
	battle.player_roster = ["hero_16", "hero_29", "hero_36"]
	battle.player_dead = 0
	battle.enemy_dead = 0
	GameState.match_running = true
	GameState.match_over = false

func _check(case: String, ok: bool, extra: String = "") -> void:
	print("[矩阵] %s => %s %s" % [case, "PASS" if ok else "FAIL", extra])
	if not ok:
		fail_total += 1

func _scene_a(mode: int) -> void:
	await _reset(mode)
	battle._pending_player_subs = 1
	battle._first_side = GameState.SIDE_PLAYER
	GameState.active_side = GameState.SIDE_PLAYER
	await battle._begin_side(GameState.SIDE_PLAYER)
	var panel: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 0
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(1, 8))
	await get_tree().create_timer(0.6).timeout
	var ok: bool = panel and battle._pending_player_subs == 0 \
			and battle.state != Battle.State.SUBSTITUTING and battle.state != Battle.State.PLACE_SUB
	_check("A死1补1 模式%d" % mode, ok)

func _scene_b(mode: int) -> void:
	await _reset(mode)
	battle._pending_player_subs = 2
	battle._first_side = GameState.SIDE_PLAYER
	GameState.active_side = GameState.SIDE_PLAYER
	await battle._begin_side(GameState.SIDE_PLAYER)
	var p1: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 1
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(1, 8))
	await get_tree().process_frame
	var p2: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 0
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_29", Vector2i(3, 8))
	await get_tree().create_timer(0.6).timeout
	var cnt := 0
	for u in battle.units:
		if u.hero_id == "hero_16" or u.hero_id == "hero_29":
			cnt += 1
	var ok: bool = p1 and p2 and cnt == 2 and battle._pending_player_subs == 0 \
			and battle.state != Battle.State.SUBSTITUTING and battle.state != Battle.State.PLACE_SUB
	_check("B死2补2 模式%d" % mode, ok, "上场=%d" % cnt)

func _scene_c(mode: int) -> void:
	await _reset(mode)
	battle._pending_player_subs = 2
	battle._first_side = GameState.SIDE_PLAYER
	GameState.active_side = GameState.SIDE_PLAYER
	await battle._begin_side(GameState.SIDE_PLAYER)
	battle.turn_time_left = 0.0
	battle._turn_expired = true
	for i in 260:
		await get_tree().process_frame
	var cnt := 0
	for u in battle.units:
		if u.hero_id == "hero_16" or u.hero_id == "hero_29":
			cnt += 1
	var stuck: bool = battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB
	var ok: bool = cnt == 2 and battle._pending_player_subs == 0 and not stuck
	_check("C超时自动补 模式%d" % mode, ok, "上场=%d 回合=%d" % [cnt, GameState.round_number])

func _run() -> void:
	for mode in 3:
		await _scene_a(mode)
		await _scene_b(mode)
		await _scene_c(mode)
	print("FINAL " + ("PASS" if fail_total == 0 else "FAIL(%d)" % fail_total))
	get_tree().quit(0 if fail_total == 0 else 1)
