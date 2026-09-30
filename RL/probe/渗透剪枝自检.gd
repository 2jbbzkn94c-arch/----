extends Node
## 【2026-09-29 晚·一次性探针·只读·用户点名】`INFILTRATE_SLOT_ONLY`（渗透类单位的阶段 1 候选收窄）读数。
##   用户原话：「宿魂移动位置被剪枝的情况还挺普遍的」—— 同一盘面跑两次（键关 / 键开），并列打：
##   阶段 1 产出的阵型数 · 送进阶段 2 的阵型数 · 阶段 2 完整计划数 · 阶段 1/2 评分数 · 思考墙钟 · 最终计划。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
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
	GameState.ai_difficulty = 3   # 噩梦：走两阶段搜索（阶段1 阵型漏斗 / 阶段2 出手），本键只在那条路上生效
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	battle._spawn_unit("hero_46", DataRegistry.Faction.ENEMY, Vector2i(0, 1))   # 宿魂（[渗透]）
	battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(1, 1))
	battle._spawn_unit("hero_25", DataRegistry.Faction.ENEMY, Vector2i(2, 1))
	battle._spawn_unit("hero_48", DataRegistry.Faction.PLAYER, Vector2i(3, 4))
	battle._spawn_unit("hero_23", DataRegistry.Faction.PLAYER, Vector2i(2, 4))
	battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(4, 4))
	for i in 4:
		await get_tree().process_frame
	await _arm(0)
	await _arm(1)
	print("SOUL|END")
	get_tree().quit(0)

func _arm(flag: int) -> void:
	var ai = battle._make_battle_ai()
	if ai == null:
		print("SOUL|键=%d|拿不到 AI 实例" % flag)
		return
	ai.difficulty = GameState.ai_difficulty
	ai.w_infiltrate_slot_only = flag
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var steps: Array = []
	for st in plan:
		var a: Dictionary = st["action"]
		steps.append("%s{move=%s,atk=%d}" % [String(sim.units[int(st["idx"])].name), str(a.get("move", null)), int(a.get("atk", -1))])
	print("SOUL|键=%s｜阵型产出=%d｜送阶段2=%d｜完整计划=%d｜阶段1评分=%d｜阶段2评分=%d｜墙钟=%dms｜计划=%s" % [
		("开" if flag > 0 else "关"), ai.last_tp_layouts_built, ai.last_tp_layouts_used, ai.last_tp_leaves,
		ai.last_tp_p1_evals, ai.last_tp_p2_evals, ms, " → ".join(steps)])
