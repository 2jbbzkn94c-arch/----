extends Node
## 【2026-10-02·一次性探针·只读·用户「黄金矿工不要替补出」】
##   验 `Battle.SUB_NEVER`（现役 = ["hero_42"] 黄金矿工）两条替补路径都挡得住：
##     臂 A 动态池：`_dynamic_sub_candidates()` 里**没有** hero_42（对照：它在英雄表里、且在"已用过"名单外）
##     臂 B 预设席：`_strip_never_subs()` 把 hero_42 从 `enemy_roster` 摘掉，剩下的人索引/顺序不乱
##     臂 C 兜底：名单里**只有** hero_42 时**不摘**（宁可按老规矩上个矿工，也不能让 AI 没人可上）
##   输出：GM|… / GM|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _rebuild()
	var has_def: bool = DataRegistry.heroes.has("hero_42")
	# ---- 臂 A：动态池 ----
	GameState.enemy_recipe = { "dynamic_bench": true }
	battle.enemy_roster = []
	battle.player_roster = []
	var pool: Array = battle._dynamic_sub_candidates()
	var a_ok: bool = has_def and not pool.has("hero_42") and pool.size() > 5
	print("GM|A_动态池|英雄表里有 hero_42=%s｜动态池 %d 人｜池里有 hero_42=%s ⇒ %s" % [
		str(has_def), pool.size(), str(pool.has("hero_42")), ("**PASS**" if a_ok else "**FAIL**")])
	# ---- 臂 B：预设席（掺一个矿工进去）----
	battle.enemy_roster = ["hero_42", "hero_40", "hero_42"]
	battle._strip_never_subs()
	var b_ok: bool = battle.enemy_roster == ["hero_40"]
	var idx := battle._best_enemy_sub_idx()
	var picked: String = String(battle.enemy_roster[idx]) if (idx >= 0 and idx < battle.enemy_roster.size()) else ""
	print("GM|B_预设席|名单 [hero_42, hero_40, hero_42] ⇒ %s｜需求制选中=%s ⇒ %s" % [
		str(battle.enemy_roster), picked, ("**PASS**" if (b_ok and picked != "hero_42") else "**FAIL**")])
	# ---- 臂 C：只剩矿工（兜底不许摘空）----
	battle.enemy_roster = ["hero_42"]
	battle._strip_never_subs()
	var c_ok: bool = battle.enemy_roster == ["hero_42"]
	print("GM|C_只剩矿工|名单 [hero_42] ⇒ %s（不摘空、AI 还有人可上）⇒ %s" % [
		str(battle.enemy_roster), ("**PASS**" if c_ok else "**FAIL**")])
	# ---- 臂 D：思考上限（顺带验第 2 条：噩梦1 = 120000，噩梦仍 40000）----
	#   真链路：按难度取权重文件 → `set_weights` 注入 ⇒ 读 AI 实例上的 `time_budget_ms`
	var shown: Array = []
	var b3 := 0
	var b4 := 0
	for d in [3, 4]:
		GameState.ai_difficulty = d
		var ai = battle._make_battle_ai()
		var ms: int = int(ai.time_budget_ms) if ai != null else -1
		shown.append("难度%d=%dms" % [d, ms])
		if d == 3:
			b3 = ms
		else:
			b4 = ms
	var d_ok: bool = (b3 == 40000 and b4 == 120000)
	print("GM|D_思考上限|%s ⇒ %s（期望 噩梦=40000 / 噩梦1=120000）" % [
		"｜".join(shown), ("**PASS**" if d_ok else "**FAIL**")])
	print("GM|END")
	get_tree().quit(0)

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
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
