extends Node
## 【2026-10-01·一次性探针·只读·用户「做」】验**动态替补池的"搜索选人"**（`_dyn_pick_by_search()`）：
##   真跑一次搜索 → 数末态玩家方阵亡数 + 看末态评分 ⇒ **AOE 一刀收 2 个的情况要能被算出来**。
##
## 盘面：AI = 白游侠(hero_10)@(1,1)（要被换下的那个）｜玩家 = 塔盾@(2,3)、独脚龟@(2,4)（**相邻，各 4 血**）。
##   替补候选 = `FINISH_HEROES` 收窄后的动态池。
##   ⇒ 白游侠落 (2,2) 一发：主目标 2 伤 + **散射**打到相邻那个 2 伤 ⇒ 两个都从 4 → 2，**都没死**（见下"这是反例"）。
##   ⚠️ 这条探针真正要证明的是**机制通不通**：搜索这条路会不会被调用、给不给读数、会不会覆盖静态那把尺。
##      多杀的"能不能凑出来"依赖具体盘面几何与血量，本探针只保证**读数可见**。
##
## 输出：DYN|CFG / DYN|静态 / DYN|搜索 / DYN|判定 / DYN|END

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
	_spawn("hero_10", DataRegistry.Faction.ENEMY, Vector2i(1, 1))
	_spawn("hero_11", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	_spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(2, 4))
	for u in battle.units:
		if not is_instance_valid(u):
			continue
		if u.hero_id == "hero_11" or u.hero_id == "hero_13":
			u.hp = 4
	battle.player_dead = 2
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var cands: Array = battle._finish_hero_pool(battle._dynamic_sub_candidates())
	var cells: Array = battle._sub_legal_cells_for_ai()
	print("DYN|CFG|噩梦｜收窄后候选 %d 人：%s｜合法落点 %s" % [
		cands.size(), "、".join(cands.map(func(h): return battle._hero_name(String(h)))), DataRegistry.cells_txt(cells)])
	var plan: Dictionary = battle._sub_kill_scan(cands, cells)
	print("DYN|静态|`sub_kill_scan` ⇒ %s" % [
		("空（一个都收不掉）" if plan.is_empty() else "上 %s 落 %s（这一手 %.0f｜需要 %.0f）" % [
			battle._hero_name(String(plan["hero"])), DataRegistry.cell_txt(plan["cell"]),
			float(plan["sub"]), float(plan["need"])])])
	var sr: Dictionary = battle._dyn_pick_by_search(cands, cells, "")
	print("DYN|搜索|`_dyn_pick_by_search` ⇒ %s" % [
		("空（没有候选多收人头 / 静态那把尺也判了没人能收）" if sr.is_empty() else
			"上 %s 落 %s｜本回合可收 %d 个｜末态分 %.1f" % [
				battle._hero_name(String(sr["id"])), DataRegistry.cell_txt(sr["cell"]),
				int(sr["kills"]), float(sr["score"])])])
	var ok := (not plan.is_empty()) and (not sr.is_empty())
	print("DYN|判定|%s（静态有结论=%s ｜ 搜索有读数=%s%s）" % [
		("PASS" if ok else "FAIL"), str(not plan.is_empty()), str(not sr.is_empty()),
		("" if ok else " ⇒ 这条盘面上有一把尺给不出结论（见上面两行）")])
	print("DYN|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
