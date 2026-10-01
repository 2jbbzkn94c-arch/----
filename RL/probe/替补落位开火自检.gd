extends Node
## 【2026-10-01·一次性探针·只读·用户「主动撤人成功了，替补上来的人为什么不攻击啊」】
##   验证「斩杀撤人」的替补落位之后**真的把那一刀打出去**（而不是只走位不出手）。
##
## 走的是**真链路**（不手工塞 pick 结果）：
##   `_ai_finish_withdraw_pick()`（挑人 + 挑落点/开火格）→ `_ai_finish_withdraw_apply()`
##   （撤下 → 按开火格落位 → `_plan_enemy_late_sub()` 补那一手）⇒ 再看替补站在哪、`_ai_plan` 尾步是什么。
##
## 盘面（最小）：AI = 塔盾(hero_11)@(1,2)（要被撤下的那个）｜玩家 = 无人机(hero_12?)… 见下
##   · 要被撤下的那个：**别拿替补本人**（`_finish_withdraw_victim()` 会把"这回合还没出手、攻最低"的那个撤掉）
##   · 替补 = 红帽(hero_40)：**近战（射程 1）+ 攻 5 + 移动 2** ⇒ 走一步贴身就能一刀收掉 5 血
##   · 目标 = 玩家方一个 5 血单位，摆在 (0,3)
##   预期：pick 把落点定成**开火格**（(0,3) 的相邻格）⇒ 替补落上去、原地开火 ⇒ 目标被打死。
##
## 判定（三条同时成立才算过）：① 替补上场了 ② 它站在 pick 记下的开火格上
##   ③ 追加的那一步**带攻击**（不是"只走位、没出手"）。
##
## 输出：SUB|CFG / SUB|判定 / SUB|END

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3          # 噩梦（走 fork）
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
	_spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(1, 2))   # 塔盾（本次要撤下的那个）
	_spawn("hero_30", DataRegistry.Faction.PLAYER, Vector2i(0, 3))  # 嬉皮死神（5 血目标）
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == "hero_30":
			u.hp = 5
	battle.player_dead = 2        # 玩家方已死 2 名 ⇒ 打死场上谁都算赢（斩杀撤人的触发条件）
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	# 预设替补席 = 红帽（近战 5 攻）；关掉"搜索选人"（它要开线程，探针里没必要）
	battle.enemy_roster = ["hero_40"]
	battle.sub_by_search = false
	battle._enemy_plan_running = true
	print("SUB|CFG|噩梦｜替补席=%s｜玩家方已死=%d｜目标血=%d" % [
		str(battle.enemy_roster), battle.player_dead, _hp_of("hero_11")])
	# 候选替补的真实身板（选"走一步再开火"那一支要它够得着又打得死）
	for hid2 in ["hero_13", "hero_40", "hero_20", "hero_35", "hero_45", "hero_27", "hero_10", "hero_11"]:
		var d2 = DataRegistry.get_hero(hid2)
		if d2 != null:
			print("SUB|身板|%s %s｜攻 %d｜射程 %d｜移动 %d｜血 %d" % [
				hid2, String(d2.display_name), int(d2.atk), int(d2.attack_range),
				int(d2.move_range), int(d2.max_hp)])
	# ① pick：挑人 + 挑落点/开火格
	battle._ai_finish_withdraw_pick()
	var hero := String(battle._finish_withdraw_hero)
	var cell: Vector2i = battle._finish_withdraw_cell
	var fire: Vector2i = battle._finish_fire_cell
	print("SUB|①pick|换=%s｜落点=%s｜开火格=%s｜目标=%s" % [
		hero, DataRegistry.cell_txt(cell), DataRegistry.cell_txt(fire), _name_of(battle._finish_withdraw_target)])
	# ② 撤下 + 落位 + 补那一手
	await battle._ai_finish_withdraw_apply()
	for i in 2:
		await get_tree().process_frame
	# ③ 复核
	var sub: Unit = null
	for u in battle.units:
		if is_instance_valid(u) and u.alive and u.hero_id == hero:
			sub = u
	var last: Dictionary = {}
	if battle._ai_plan.size() > 0:
		last = battle._ai_plan[battle._ai_plan.size() - 1]
	var act: Dictionary = last.get("action", {})
	var atk_i := int(act.get("atk", -1))
	var fired := (atk_i >= 0)
	var hit_name := ""
	if fired and atk_i < battle._enemy_refs.size():
		var r = battle._enemy_refs[atk_i]
		if r != null and is_instance_valid(r):
			hit_name = String(r.display_name)
	var on_fire := (sub != null and sub.cell == fire)
	var alive_txt := "目标已阵亡" if _hp_of("hero_11") <= 0 else ("目标还在（血 %d）" % _hp_of("hero_11"))
	print("SUB|②落位后|替补=%s｜实际格=%s｜站在开火格上=%s｜尾步=%s" % [
		(hero if sub != null else "（没上场）"), (DataRegistry.cell_txt(sub.cell) if sub != null else "-"),
		str(on_fire), str(act)])
	print("SUB|③那一刀|出手=%s%s｜%s" % [
		str(fired), ("（打 %s）" % hit_name if hit_name != "" else ""), alive_txt])
	var pass_all := (sub != null) and on_fire and fired
	print("SUB|判定|%s（替补上场=%s ｜ 站在开火格=%s ｜ 尾步带攻击=%s）" % [
		("PASS" if pass_all else "FAIL"), str(sub != null), str(on_fire), str(fired)])
	print("SUB|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false

func _hp_of(hid: String) -> int:
	for u in battle.units:
		if is_instance_valid(u) and u.hero_id == hid:
			return int(u.hp) if u.alive else 0
	return -1

func _name_of(u) -> String:
	return (String(u.display_name) if (u != null and is_instance_valid(u)) else "（无）")
