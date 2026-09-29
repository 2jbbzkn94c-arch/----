extends Node
## 【2026-09-28 一次性探针】"中毒 1 血的 AI 单位：打完这一手就撤、换替补上场" 自检。
## 要回答的：
##   ① 检测有没有登记它（`_ai_poison_withdraw_pick`）？本回合它有没有**照常行动**（不被提前拿掉）？
##   ② 行动完有没有真撤下（`_ai_poison_withdraw_apply`）→ 记进敌方阵亡数 + 换到替补名额？
##   ③ 替补有没有**当场落位**、并且**补一手**（追加到 `_ai_plan` 尾部）？
##   ④ 两个护栏：敌方已阵亡 2 名 ⇒ 不撤；替补席空 ⇒ 不撤。
## 输出：每行 `PW|...`，末尾 `PW|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	print("PW|CFG|噩梦权重=%s｜本端阵营=%d｜敌方阵营=%d｜难度=%d" % [
		str(FileAccess.file_exists("res://RL/weights/噩梦.json")), int(battle._my_faction()),
		int(DataRegistry.Faction.ENEMY), int(GameState.ai_difficulty)])
	_cfg()

	# ---- 主线：敌方 1 血 + 毒（毒是**这一回合**挂的 ⇒ 活过本回合、死在下一个我方回合开场）----
	var v = battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(2, 2))
	v.hp = 1
	v.remove_status(StatusDB.SHIELD)
	battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	battle._spawn_unit("hero_09", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	for i in 2:
		await get_tree().process_frame
	v.add_status(StatusDB.POISON, true)
	print("PW|摆盘|敌方 %s(毒/血 %d)@%s｜玩家 %s｜敌替补席 %s｜敌阵亡=%d" % [
		str(v.display_name), int(v.hp), str(v.cell), _foe_txt(), str(battle.enemy_roster), int(battle.enemy_dead)])

	# 手动跑一次敌方回合（`_begin_side` → 技能段 → `_run_enemy_turn`）
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	battle._ai_poison_withdraw_pick()
	print("PW|检测|名单=%d｜登记了 %s" % [
		battle._poison_withdraw_wanted.size(), _names(battle._poison_withdraw_wanted)])
	# 等到"毒 tick 已经结算过"再登记一次（真实流程里 `_run_enemy_turn` 就是在 tick 之后调的）
	var waited := 0.0
	while waited < 2.6:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if not v.alive:
		print("PW|!!|毒 tick 把它收了（本探针是手动登记，时机没卡住）")
	else:
		print("PW|tick 后|它活着 血=%d ⇒ 这才是要撤的那批" % int(v.hp))

	battle.enemy_roster = ["hero_07"]
	battle._enemy_plan_running = true
	battle._pending_enemy_sub = 0
	battle._ai_plan = []
	var before_dead := int(battle.enemy_dead)
	var before_alive := battle._foe_alive_count()
	await battle._ai_poison_withdraw_apply()
	for i in 6:
		await get_tree().process_frame
	print("PW|撤下后|敌阵亡 %d→%d｜敌存活=%d｜待补=%d｜场上敌方=%s｜替补席=%s" % [
		before_dead, int(battle.enemy_dead), battle._foe_alive_count(), int(battle._pending_enemy_sub),
		_enemy_units(), str(battle.enemy_roster)])
	print("PW|补的那一手|步数=%d｜内容=%s" % [battle._ai_plan.size(), _plan_txt()])

	# ---- 护栏 A：敌方已阵亡 2 名 ⇒ 不撤 ----
	battle.enemy_dead = 2
	battle.enemy_roster = ["hero_07"]
	battle._pending_enemy_sub = 0
	var v2 = battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(4, 2))
	v2.hp = 1
	v2.remove_status(StatusDB.SHIELD)
	v2.add_status(StatusDB.POISON, true)
	battle._poison_withdraw_wanted = [v2]
	var alive_before := battle._foe_alive_count()
	await battle._ai_poison_withdraw_apply()
	for i in 3:
		await get_tree().process_frame
	print("PW|护栏A(已死2)|存活 %d→%d｜待补=%d｜%s 还活着=%s（期望：不撤、还活着）" % [
		alive_before, battle._foe_alive_count(), int(battle._pending_enemy_sub),
		str(v2.display_name), str(v2.alive)])

	# ---- 护栏 B：替补席空 ⇒ 不撤 ----
	battle.enemy_dead = 0
	battle.enemy_roster = []
	battle._pending_enemy_sub = 0
	var v3 = battle._spawn_unit("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 1))
	v3.hp = 1
	v3.remove_status(StatusDB.SHIELD)
	v3.add_status(StatusDB.POISON, true)
	battle._poison_withdraw_wanted = [v3]
	var alive_before2 := battle._foe_alive_count()
	await battle._ai_poison_withdraw_apply()
	for i in 3:
		await get_tree().process_frame
	print("PW|护栏B(无替补)|存活 %d→%d｜%s 还活着=%s（期望：不撤、还活着）" % [
		alive_before2, battle._foe_alive_count(), str(v3.display_name), str(v3.alive)])

	print("PW|END")
	get_tree().quit(0)

func _cfg() -> void:
	battle.enemy_roster = ["hero_07"]
	battle.player_roster = []

func _names(arr: Array) -> String:
	var bits: Array[String] = []
	for x in arr:
		if x != null and is_instance_valid(x):
			bits.append(str((x as Unit).display_name))
	return "／".join(bits) if bits.size() > 0 else "（空）"

func _enemy_units() -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			bits.append("%s@%s" % [str(u.display_name), str(u.cell)])
	return "／".join(bits) if bits.size() > 0 else "（无）"

func _foe_txt() -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.PLAYER:
			bits.append("%s@%s" % [str(u.display_name), str(u.cell)])
	return "／".join(bits) if bits.size() > 0 else "（无）"

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
