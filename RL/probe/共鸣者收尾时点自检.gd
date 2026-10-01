extends Node
## 【2026-10-01·一次性探针·只读·用户实机「共鸣者这个没修好啊，还是主动撤下，上了个 0 攻」】
##   验**共鸣者(hero_47) 只在"回合开始的先补位"那个时点才该进收尾名单**：
##     · 回合中途（斩杀撤人 / 死亡即时补位）⇒ echo 还没结算 ⇒ **0 攻** ⇒ 不许当收尾人选；
##     · 回合开始的先补位（`_start_placing_subs = true`）⇒ echo 会生效 ⇒ 允许。
##
## 盘面：AI 塔盾@(1,2)（要被撤下的那个）｜玩家 沉默术士@(2,3)（**1 血**）。
##   替补候选 = 动态池收窄后的名单 —— 只有共鸣者能"走+打"够到它（其它候选射程/移动不够时同理）。
##   看点：`_finish_hero_pool()` 在两个时点给出的名单**不一样**（中途没有 hero_47、回合开始有）。
##
## 输出：ECHO|CFG / ECHO|中途 / ECHO|开场 / ECHO|判定 / ECHO|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
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
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	_spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(1, 2))
	_spawn("hero_34", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_34":
			u.hp = 1
	battle.player_dead = 2
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	print("ECHO|CFG|噩梦｜玩家方已死=%d｜目标 沉默术士 血=%d" % [battle.player_dead, _hp("hero_34")])
	# 动态池里 hero_47 在不在（原料）
	var raw: Array = battle._dynamic_sub_candidates()
	print("ECHO|原料|动态池 %d 人｜含 hero_47 = %s" % [raw.size(), str(raw.has("hero_47"))])
	# ① 回合中途（`_start_placing_subs = false`）
	battle._start_placing_subs = false
	var mid: Array = battle._finish_hero_pool(raw)
	print("ECHO|中途|收窄后 %d 人｜含 hero_47 = %s ⇒ %s" % [
		mid.size(), str(mid.has("hero_47")),
		("正确（中途落位 echo 没结算 ⇒ 0 攻，不该进名单）" if not mid.has("hero_47") else "**错**：0 攻的共鸣者进名单了")])
	# ② 回合开始的先补位（`_start_placing_subs = true`）
	battle._start_placing_subs = true
	var early: Array = battle._finish_hero_pool(raw)
	print("ECHO|开场|收窄后 %d 人｜含 hero_47 = %s ⇒ %s" % [
		early.size(), str(early.has("hero_47")),
		("正确（回合开始落位 echo 会结算 ⇒ 允许）" if early.has("hero_47") else "**错**：该放行时被挡")])
	var ok := (not mid.has("hero_47")) and early.has("hero_47")
	print("ECHO|判定|%s" % ("PASS" if ok else "FAIL"))
	print("ECHO|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false

func _hp(hid: String) -> int:
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == hid:
			return int(u.hp) if u.alive else 0
	return -1
