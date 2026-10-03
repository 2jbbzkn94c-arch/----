extends Node
## 【2026-10-02·一次性探针·只读·用户「这次会主动撤下下回合开始必被毒死的英雄了，**但是替补的英雄没有行动**」】
##
## 验：**中毒撤人**（`_ai_poison_withdraw_apply()`）落位之后，有没有给替补**补上那一手**。
##   病灶：那条路少了"把计划标志支起来 ＋ 补回 `_enemy_refs` ＋ 把追加步演完"这三样
##   （斩杀撤人 `_ai_finish_withdraw_apply()` 有）⇒ `_plan_enemy_late_sub()` 第一行就 `return`
##   ⇒ 替补落位却干站着。
##
## ⚠️ 探针必须先把 `Main.tscn` 自带的**对局 prologue 作废**（`_session_id += 1`）：
##   它自己会起一整轮 AI 回合（`_begin_side` → `_run_enemy_turn`），会把替补席吃掉、把状态改掉。
##
## 输出：PW|… / PW|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2          # 低档 ⇒ 不注入权重 ⇒ 关掉「搜索选人」后整条链**同步**（探针里好定位）
	# ---- 臂 A：完整链路（登记 → 回放跑完 → 撤人落位）----
	battle = await _fresh_board()
	battle._ai_poison_withdraw_pick()
	print("PW-A|①登记|待撤名单=%d 个｜替补席=%s" % [battle._poison_withdraw_wanted.size(), str(battle.enemy_roster)])
	await battle._replay_enemy_plan([], [], battle._session_id)
	print("PW-A|②回放跑完|_enemy_plan_running=%s｜_enemy_refs=%d｜_ai_plan=%d 步｜_replay_plan_pos=%d" % [
		str(battle._enemy_plan_running), battle._enemy_refs.size(), battle._ai_plan.size(), battle._replay_plan_pos])
	var before: int = battle._ai_plan.size()
	var alive_before: Array = _alive_list()
	await battle._ai_poison_withdraw_apply()
	for i in 3:
		await get_tree().process_frame
	var sub = _new_alive(alive_before)
	var doomed = _find("hero_11")
	var last: Dictionary = (battle._ai_plan[battle._ai_plan.size() - 1] if battle._ai_plan.size() > 0 else {})
	print("PW-A|③撤人+落位后|_ai_plan %d → %d 步｜追加步=%s｜替补=%s｜要撤的那个还在场=%s" % [
		before, battle._ai_plan.size(),
		(str(last.get("action", {})) if not last.is_empty() else "（没追加）"),
		(String(sub.display_name) + "@" + str(sub.cell) if sub != null else "（没上场）"),
		str(doomed != null and doomed.alive)])
	var ok: bool = (sub != null) and (battle._ai_plan.size() > before)
	print("PW-A|判定|%s（替补上场=%s ｜ 补了那一手=%s）" % [
		("**PASS**" if ok else "**FAIL**"), str(sub != null), str(battle._ai_plan.size() > before)])
	# ---- 臂 B：只验"落位 + 补手"这一段（把标志按修复后的方式支起来）----
	battle = await _fresh_board()
	var n0: int = battle.units.size()
	battle._pending_enemy_sub = 1
	battle._enemy_plan_running = true
	battle._enemy_refs = battle.units.duplicate()
	battle._ai_plan = []
	battle._replay_plan_pos = 0
	await battle._place_enemy_sub(true)
	for i in 3:
		await get_tree().process_frame
	var sub2 = _find("hero_13")
	var last2: Dictionary = (battle._ai_plan[battle._ai_plan.size() - 1] if battle._ai_plan.size() > 0 else {})
	print("PW-B|直接落位（标志支起）|units %d → %d｜替补=%s｜_ai_plan=%d 步｜追加步=%s" % [
		n0, battle.units.size(),
		(String(sub2.display_name) + "@" + str(sub2.cell) if sub2 != null else "（没上场）"),
		battle._ai_plan.size(), (str(last2.get("action", {})) if not last2.is_empty() else "（没追加）")])
	# ---- 臂 C：**对照** —— 标志不支起（= 改前的行为）----
	battle = await _fresh_board()
	battle._pending_enemy_sub = 1
	battle._enemy_plan_running = false      # ← 改前 `_ai_poison_withdraw_apply()` 在落位时就是这个状态
	battle._enemy_refs = []
	battle._ai_plan = []
	battle._replay_plan_pos = 0
	await battle._place_enemy_sub(true)
	for i in 3:
		await get_tree().process_frame
	var sub3 = _find("hero_13")
	print("PW-C|对照·标志不支起|替补=%s｜_ai_plan=%d 步（改前就是这样 ⇒ 落位但不补手）" % [
		(String(sub3.display_name) + "@" + str(sub3.cell) if sub3 != null else "（没上场）"), battle._ai_plan.size()])
	print("PW|END")
	get_tree().quit(0)

func _fresh_board() -> Battle:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 3:
			await get_tree().process_frame
	var b := (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(b)
	for i in 6:
		await get_tree().process_frame
	for u in b.units:
		if is_instance_valid(u):
			u.queue_free()
	b.units.clear()
	b.occupancy.clear()
	b.graves.clear()
	b.obstacles.clear()
	b.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	b.state = b.State.ENEMY_TURN
	# 作废 Main.tscn 自带的对局 prologue（它会自己跑一整轮 AI 回合）
	b._session_id += 1
	for i in 6:
		await get_tree().process_frame
	# 盘面：要撤的（1 血 + 中毒）· 陪衬 · 玩家靶（落位后够得到）· 替补席 = 独脚龟
	_spawn(b, "hero_11", DataRegistry.Faction.ENEMY, Vector2i(2, 3), 1, true)
	_spawn(b, "hero_40", DataRegistry.Faction.ENEMY, Vector2i(1, 3), 13, false)
	_spawn(b, "hero_30", DataRegistry.Faction.PLAYER, Vector2i(2, 2), 5, false)
	b.enemy_roster = ["hero_13"]
	b.sub_by_search = false              # 关掉后台线程版的「搜索选人」⇒ 落位那条链全同步、好定位
	b.player_dead = 0
	b.enemy_dead = 0
	b._ai_plan = []
	b._replay_plan_pos = 0
	b._enemy_refs = []
	b._enemy_plan_running = false
	b._pending_enemy_sub = 0
	b._sync_ranged_adjacent()
	b._refresh_board()
	return b

func _spawn(b: Battle, hid: String, fn, cell: Vector2i, hp: int, poison: bool):
	var u = b._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		if hp > 0:
			u.hp = hp
		if poison:
			u.add_status(StatusDB.POISON)
	return u

func _alive_list() -> Array:
	var out: Array = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive:
			out.append(u)
	return out

func _new_alive(before: Array):
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and not before.has(u):
			return u
	return null

func _find(hid: String):
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.hero_id == hid:
			return u
	return null
