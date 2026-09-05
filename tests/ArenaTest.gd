extends Node
## 竞技场模式冒烟测试：8轮选人（前4玩家、后4敌方），最终双方各8名。
## 运行：godot --headless --scene res://tests/ArenaTest.tscn
var battle: Battle

func _ready() -> void:
	GameState.arena_mode = true
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _run() -> void:
	# 等选人流程开始（state=ARENA_DRAFT 且已弹第一轮）
	for i in 120:
		await get_tree().process_frame
		if battle.state == Battle.State.ARENA_DRAFT and battle._arena_pending.size() == 2:
			break
	print("A1 进入竞技场选人: state=%d pending=%s => %s" % [battle.state, str(battle._arena_pending), "PASS" if battle.state == Battle.State.ARENA_DRAFT else "FAIL"])

	# 玩家轮 4 次（每轮点第一个候选）
	var picked_ids: Array = []
	for round_i in 4:
		await get_tree().process_frame
		var pick: String = battle._arena_pending[0]
		print("A2 玩家第%d轮点击: %s" % [round_i + 1, pick])
		battle._on_arena_pick(pick)
		picked_ids.append(pick)
		await get_tree().process_frame
		# 实时校验：每选完一轮，下方队伍应包含已选英雄
		var live := battle._player_team_ids()
		if round_i == 1:
			print("A2b 选人实时更新: live=%s => %s" % [str(live), "PASS" if live.size() == picked_ids.size() and live.has(pick) else "FAIL"])

	# 全部轮次自动推进（敌轮同步执行），等状态脱离 ARENA_DRAFT
	for i in 240:
		await get_tree().process_frame
		if battle.state != Battle.State.ARENA_DRAFT:
			break

	print("A3 全部8轮结束: state=%d p_deck=%d e_deck=%d => %s" % [battle.state, GameState.player_deck.size(), GameState.enemy_deck.size(), "PASS" if GameState.player_deck.size() == 8 and GameState.enemy_deck.size() == 8 else "FAIL"])
	# 双方卡组无重复（8轮16个英雄全部不同）
	var concat: Array = GameState.player_deck.duplicate() + GameState.enemy_deck.duplicate()
	var uniq := {}
	for h in concat:
		uniq[h] = true
	print("A4 卡组无重复: %d/%d => %s" % [uniq.size(), concat.size(), "PASS" if uniq.size() == concat.size() and uniq.size() == 16 else "FAIL"])
	# 竞技场模式持久：选完后 arena_mode 仍为 true（再来一局会重走选人）
	print("A5 竞技场模式持久: arena_mode=%s => %s" % [GameState.arena_mode, "PASS" if GameState.arena_mode else "FAIL"])

	# A6：双方带 <替补> 标签的英雄不排进前3（不发首发）
	var bench_heroes := ["hero_16", "hero_29", "hero_36", "hero_39"]   # 波盾/太阳斩/梅林/猎颅者
	var p_ok := true
	var e_ok := true
	for i in 3:
		if GameState.player_deck[i] in bench_heroes:
			p_ok = false
		if GameState.enemy_deck[i] in bench_heroes:
			e_ok = false
	print("A6 替补英雄不进首发: 我方=%s 敌方=%s => %s" % [p_ok, e_ok, "PASS" if p_ok and e_ok else "FAIL"])

	get_tree().quit()
