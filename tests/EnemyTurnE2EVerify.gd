extends Node
## 探针：整场敌方回合端到端跑通（AI 后台搜索 + 回放 + 回合末结算 + 交回我方）。
## 目的：确认加入行动间隔/行动描边后，敌方回合仍能正常收尾、不会卡住或漏交回合。
## 运行：godot --headless --scene res://tests/EnemyTurnE2EVerify.tscn
## 断言：
##  T1 敌方回合内确实执行了动作（action_finished 至少 1 次）
##  T2 回合结束后 active_side 交回我方
##  T3 我方回到可操作状态（PLAYER_INPUT）
##  T4 回放时长 ≥ 行动间隔常量之和的下限（说明间隔真的生效，不是零停顿连招）
var battle: Battle
var _acts := 0
var _guard_hit := false

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.reset_online()
	GameState.arena_mode = true
	GameState.match_over = false
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	await get_tree().process_frame
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	GameState.clear_placement()
	# 双方各 2 名：敌方在出生区，我方在中下部（距离够近，能走位+出手）
	GameState.player_placement[Vector2i(1, 4)] = "hero_13"
	GameState.player_placement[Vector2i(3, 4)] = "hero_13"
	GameState.enemy_placement[Vector2i(1, 1)] = "hero_04"
	GameState.enemy_placement[Vector2i(3, 1)] = "hero_04"
	battle._place_units()
	battle.player_roster = []
	battle.enemy_roster = []
	battle.player_dead = 0
	battle.enemy_dead = 0
	# 血量拉高：本探针只验证回合流程，不触发阵亡/替补（那会开替补面板，属于另一条流程）
	for u in battle.units:
		u.max_hp = 200
		u.hp = 200
	GameState.active_side = GameState.SIDE_ENEMY
	battle._first_side = GameState.SIDE_ENEMY
	battle.state = Battle.State.ENEMY_TURN
	battle.action_finished.connect(func(): _acts += 1)
	# 兜底：90 秒仍未收尾视为卡死（正常应在数秒内完成）
	var guard := get_tree().create_timer(90.0)
	guard.timeout.connect(func():
		_guard_hit = true
		print(">> 超时：敌方回合未在 90s 内收尾（疑似卡死）"))
	var t0 := Time.get_ticks_msec()
	await battle._run_enemy_turn()
	var dt := Time.get_ticks_msec() - t0

	var t1: bool = _acts >= 1
	var t2: bool = GameState.active_side == GameState.SIDE_PLAYER
	var t3: bool = battle.state == Battle.State.PLAYER_INPUT
	# 下限：起手 0.3 + 两名英雄各一次 0.7 + 末尾 0.25 ≈ 1.95s（外加动画时间）
	var floor_ms := int((EnemyReplay.TELL_GAP + EnemyReplay.HERO_GAP * 2.0 + EnemyReplay.STEP_GAP) * 1000.0) - 200
	var t4: bool = not _guard_hit and dt >= floor_ms
	print(">> 敌方回合耗时 %d ms（下限 %d ms），动作次数 %d，active_side=%d state=%d" % [dt, floor_ms, _acts, GameState.active_side, battle.state])
	print("T1 回合内确有动作(%d): %s" % [_acts, "PASS" if t1 else "FAIL"])
	print("T2 交回我方回合: %s" % ["PASS" if t2 else "FAIL"])
	print("T3 我方回到可操作: %s" % ["PASS" if t3 else "FAIL"])
	print("T4 回放含行动间隔(≥%dms): %s" % [floor_ms, "PASS" if t4 else "FAIL"])
	var ok: bool = t1 and t2 and t3 and t4
	print("FINAL " + ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
