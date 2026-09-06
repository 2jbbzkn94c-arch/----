extends Node
## 临时探针：同时阵亡2人（待补2）→ 应依次替补2次。
var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.arena_mode = true   # 复现竞技场模式
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	GameState.clear_placement()
	GameState.player_placement[Vector2i(2, 8)] = "hero_32"
	GameState.player_placement[Vector2i(4, 8)] = "hero_33"
	GameState.enemy_placement[Vector2i(1, 0)] = "hero_13"
	battle._place_units()
	# 待补2，替补hero_16/hero_29
	battle.player_roster = ["hero_16", "hero_29"]
	battle._pending_player_subs = 2
	battle._first_side = GameState.SIDE_PLAYER
	GameState.active_side = GameState.SIDE_PLAYER
	await battle._begin_side(GameState.SIDE_PLAYER)
	# 第一次替补
	var first: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 1
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(1, 8))
	await get_tree().create_timer(0.4).timeout
	# 应自动再弹第二次
	var second: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 0
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_29", Vector2i(3, 8))
	await get_tree().create_timer(0.6).timeout
	var done: bool = battle._pending_player_subs == 0 and battle.player_roster.size() == 0 and battle.state != Battle.State.SUBSTITUTING
	var cnt := 0
	for u in battle.units:
		if u.hero_id == "hero_16" or u.hero_id == "hero_29":
			cnt += 1
	print(">> 第一弹=%s 第二弹=%s 完成=%s 上场替补数=%d" % [first, second, done, cnt])
	var ok: bool = first and second and done and cnt == 2
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
