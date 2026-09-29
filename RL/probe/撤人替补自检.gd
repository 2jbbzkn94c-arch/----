extends Node
## 【2026-09-28 一次性探针】主动撤下 → 替补落位 → **能不能当回合出手** 自检。
## 回答用户正在设计的"主动撤人斩杀"方案的前提：
##   ① AI 撤下一人后，替补是**当回合**落位、还是顺延到下个回合？
##   ② 落位后**有没有出手**（那一手会不会被排进本回合的待执行计划 `_ai_plan`）？
##   ③ 目标的选择与落位格（`_place_enemy_sub` 内部会调 `_plan_enemy_late_sub(nu)` 追加一手）。
## 关键事实（读代码得到，探针就在这些函数上量）：
##   · `Battle._apply_withdraw()` 撤下 = 视为阵亡 ⇒ 记一个替补名额 + 立刻 `_try_begin_next_sub()`；
##   · `_on_unit_died()` 的**敌方**分支只在 `active_side == SIDE_ENEMY and _enemy_plan_running` 时当场补位；
##   · 中途落位的那一手由 `_plan_enemy_late_sub()` 追加到 `_ai_plan`（2026-09-26 修过相关的坑）。
## 输出：每行 `WD|...`，末尾 `WD|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	print("WD|CFG|权重存在=%s｜本端阵营=%d｜敌方阵营=%d" % [
		str(FileAccess.file_exists("res://RL/weights/噩梦.json")), int(battle._my_faction()),
		int(DataRegistry.Faction.ENEMY)])

	battle.player_roster = []
	battle.enemy_roster = ["hero_07"]
	var weak = battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(3, 2))
	var strong = battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	var hurt = battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(3, 5))
	hurt.hp = 4
	battle._spawn_unit("hero_09", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle._spawn_unit("hero_05", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	for i in 2:
		await get_tree().process_frame
	print("WD|摆盘|敌方 %s(待撤) + %s｜玩家 %s(血 %d) + 2 人｜敌替补席 %s" % [
		str(weak.display_name), str(strong.display_name), str(hurt.display_name), int(hurt.hp),
		str(battle.enemy_roster)])

	# ---------- ① 计划跑完之后撤（`_enemy_plan_running` = false）----------
	GameState.active_side = GameState.SIDE_ENEMY
	battle._enemy_plan_running = false
	battle._apply_withdraw(weak)
	for i in 3:
		await get_tree().process_frame
	print("WD|①撤下(计划已完)|敌存活=%d｜待补=%d｜场上敌方=%s｜替补席=%s" % [
		battle._foe_alive_count(), int(battle._pending_enemy_sub), _enemy_units(), str(battle.enemy_roster)])
	battle._place_enemy_sub(true)
	for i in 5:
		await get_tree().process_frame
	print("WD|①手动落位后|敌存活=%d｜待补=%d｜场上敌方=%s｜替补席=%s｜替补在=%s" % [
		battle._foe_alive_count(), int(battle._pending_enemy_sub), _enemy_units(),
		str(battle.enemy_roster), _sub_cell()])

	# ---------- ② 计划执行途中撤（`_enemy_plan_running` = true）----------
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.faction == DataRegistry.Faction.ENEMY and u.hero_id == "hero_07":
			battle.enemy_roster.append("hero_07")
			battle.units.erase(u)
			u.queue_free()
			break
	var weak2 = battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(3, 2))
	for i in 2:
		await get_tree().process_frame
	battle._enemy_plan_running = true
	GameState.active_side = GameState.SIDE_ENEMY
	battle._pending_enemy_sub = 0
	battle._ai_plan = []
	battle._apply_withdraw(weak2)
	for i in 90:
		await get_tree().process_frame
	print("WD|②撤下(计划进行中)|敌存活=%d｜待补=%d｜场上敌方=%s｜替补席=%s" % [
		battle._foe_alive_count(), int(battle._pending_enemy_sub), _enemy_units(), str(battle.enemy_roster)])
	print("WD|②待执行计划|步数=%d｜内容=%s" % [battle._ai_plan.size(), _plan_txt()])
	print("WD|②目标|%s 血=%d｜场上敌方=%s" % [str(hurt.display_name), int(hurt.hp), _enemy_units()])
	print("WD|END")
	get_tree().quit(0)

func _plan_txt() -> String:
	var bits: Array[String] = []
	for st in battle._ai_plan:
		var a: Dictionary = (st as Dictionary).get("action", {})
		var idx := int((st as Dictionary).get("idx", -1))
		var nm := "?"
		if idx >= 0 and idx < battle._enemy_refs.size():
			var rr = battle._enemy_refs[idx]
			if rr != null and is_instance_valid(rr):
				nm = str(rr.display_name)
		bits.append("%s{move=%s,atk=%s}" % [nm, str(a.get("move")), str(a.get("atk"))])
	return "／".join(bits) if bits.size() > 0 else "（空）"

func _enemy_units() -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			bits.append("%s@%s(距目标%d)" % [str(u.display_name), str(u.cell),
				int(battle.grid.distance(u.cell, Vector2i(3, 5)))])
	return "／".join(bits) if bits.size() > 0 else "（无）"

func _sub_cell() -> String:
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY and u.hero_id == "hero_07":
			return str(u.cell)
	return "（没上场）"
