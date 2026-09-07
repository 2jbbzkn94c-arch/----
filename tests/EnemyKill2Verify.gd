extends Node
## 临时探针：敌方回合我方双死(active=ENEMY) → 下一我方回合应补2个。
var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.arena_mode = true
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	GameState.clear_placement()
	GameState.player_placement[Vector2i(2, 6)] = "hero_32"
	GameState.player_placement[Vector2i(4, 6)] = "hero_33"
	GameState.player_placement[Vector2i(1, 6)] = "hero_43"
	GameState.enemy_placement[Vector2i(1, 0)] = "hero_13"
	GameState.enemy_placement[Vector2i(3, 0)] = "hero_12"
	battle._place_units()
	battle.player_roster = ["hero_16", "hero_29", "hero_36", "hero_39", "hero_06"]
	battle.enemy_roster = ["hero_16"]
	battle.player_dead = 0
	battle.enemy_dead = 0
	# 敌方回合：击杀我方 hero_32 与 hero_33（先后两次死亡处理）
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = Battle.State.ENEMY_TURN
	var victims: Array = []
	for u in battle.units:
		if u.faction == DataRegistry.Faction.PLAYER and (u.hero_id == "hero_32" or u.hero_id == "hero_33"):
			victims.append(u)
	for v in victims:
		v.hp = 0
		battle._on_unit_died(v)
	print(">> 敌方回合双死后 待补=%d roster=%d" % [battle._pending_player_subs, battle.player_roster.size()])
	var queued: bool = battle._pending_player_subs == 2
	# 进入我方回合（回合开始先补位）
	GameState.active_side = GameState.SIDE_PLAYER
	battle._first_side = GameState.SIDE_PLAYER
	await battle._begin_side(GameState.SIDE_PLAYER)
	var p1: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 1
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(1, 6))
	await get_tree().create_timer(0.4).timeout
	var p2: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 0
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_29", Vector2i(3, 6))
	await get_tree().create_timer(0.6).timeout
	var ok_end: bool = battle._pending_player_subs == 0 and battle.state != Battle.State.SUBSTITUTING
	print(">> 开局后第一弹=%s 第二弹=%s 收尾=%s" % [p1, p2, ok_end])
	var ok: bool = queued and p1 and p2 and ok_end
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
