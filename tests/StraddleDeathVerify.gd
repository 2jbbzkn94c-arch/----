extends Node
## 临时探针：敌方回合致死但死亡事件落入我方"回合开始演出期"→ 先排队，演出后弹1次面板，不叠层。
var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _kill(u: Unit) -> void:
	u.hp = 0
	battle._on_unit_died(u)

func _run() -> void:
	GameState.reset_online()
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	GameState.clear_placement()
	GameState.player_placement[Vector2i(2, 6)] = "hero_43"   # 回合开始技(风语者)保证演出期有 await 窗口
	GameState.player_placement[Vector2i(4, 6)] = "hero_32"
	GameState.enemy_placement[Vector2i(1, 0)] = "hero_13"
	battle._place_units()
	battle.player_roster = ["hero_16"]
	battle.player_dead = 0
	battle.enemy_dead = 0
	GameState.match_running = true
	GameState.match_over = false
	battle._first_side = GameState.SIDE_PLAYER
	GameState.active_side = GameState.SIDE_PLAYER
	var victim: Unit = null
	for u in battle.units:
		if u.faction == DataRegistry.Faction.PLAYER and u.hero_id == "hero_32":
			victim = u
	# 预挂 0.1s：回合开始演出（风语者技能 0.35s 闪烁）进行到一半时把阵亡事件“晚到”进来
	get_tree().create_timer(0.1).timeout.connect(func(): _kill(victim))
	await battle._begin_side(GameState.SIDE_PLAYER)
	await get_tree().create_timer(0.3).timeout
	print(">> 演出结束后: 面板=%s 待补=%d" % [battle.state == Battle.State.SUBSTITUTING, battle._pending_player_subs])
	var panel_once: bool = battle.state == Battle.State.SUBSTITUTING and battle._pending_player_subs == 0
	battle._place_sub(DataRegistry.Faction.PLAYER, "hero_16", Vector2i(1, 6))
	await get_tree().create_timer(0.7).timeout
	var ok_end: bool = battle._pending_player_subs == 0 and battle.state != Battle.State.SUBSTITUTING \
			and battle.state != Battle.State.PLACE_SUB
	var cnt := 0
	for u in battle.units:
		if u.hero_id == "hero_16":
			cnt += 1
	print(">> 补齐后: 上场=%d 状态不再面板=%s" % [cnt, ok_end])
	var ok: bool = battle._pending_player_subs >= 0 and panel_once and ok_end and cnt == 1
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
