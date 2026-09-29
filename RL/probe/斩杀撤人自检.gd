extends Node
## 【2026-09-28 一次性探针】"斩杀撤人"自检 —— 用户口径：
##   **对手已死 2 个、场上只剩 1 个残血**，而我这一回合出手全打完了还收不掉它
##   ⇒ 撤一个**已经行动完**的单位，换替补上来**一刀收尾**（"建立在所有英雄已经行动"）。
## ⚠️ 两个计数器别混（本探针第一版就混了，白跑一轮）：
##   · `player_dead` = **对手（玩家）**的阵亡数 —— 决定"打死下一个就赢"；
##   · `enemy_dead`  = **我自己（AI）**的阵亡数 —— 决定"再撤一个会不会判负"（判负线 3）。
##   撤下 = 视为阵亡 ⇒ **我自己** 会 +1。
## 三个自足的局面（各起一局新场景，互不污染）：
##   ① 触发：对手已死 2、场上只剩 1 个残血、我方两人都够不到它 ⇒ 应"撤下 + 替补落位 + 补一手"；
##   ② 护栏 A：对手场上不止 1 个 ⇒ 不撤；
##   ③ 护栏 B：我方有个单位**原地就够得到**它 ⇒ 不撤（这一回合本来就收得掉）。
## 输出：每行 `FW|...`，末尾 `FW|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _arm_trigger()
	await _arm_guard_multi()
	await _arm_guard_reachable()
	print("FW|END")
	get_tree().quit(0)

## 起一局干净盘面：敌方 塔盾(0,0) + 巨剑(0,8)（都够不到目标），敌替补 影丸（5 攻 2 射程）；
## 玩家 白游侠(2,3) 血 3（+ 可选陪衬）。
## ⚠️ `player_dead` = 对手已死 2（场上就剩这一个）是**局面事实**，不是硬设的数：
##    3 人阵容里"台上只剩 1 个"就等价于"已死 2 个"。
func _fresh(extra_players: int) -> Unit:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	battle.player_roster = []
	battle.enemy_roster = ["hero_07"]
	battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(0, 0))
	battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(0, 8))
	var hurt = battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	hurt.hp = 3
	if extra_players >= 1:
		battle._spawn_unit("hero_09", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	if extra_players >= 2:
		battle._spawn_unit("hero_05", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle.player_dead = 2          # 对手已死 2 个（台上这个就是它最后一个）
	battle.enemy_dead = 0           # 我自己一个没死 ⇒ 撤一个也才 1，离判负线 3 还远
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	return hurt

func _arm_trigger() -> void:
	var hurt := await _fresh(0)            # 台上只剩它一个
	print("FW|①摆盘|敌方=%s｜目标 %s@%s 血=%d｜敌替补=%s｜对手已死=%d｜我方已死=%d" % [
		_enemy_units(), str(hurt.display_name), str(hurt.cell), int(hurt.hp),
		str(battle.enemy_roster), int(battle.player_dead), int(battle.enemy_dead)])
	battle._ai_finish_withdraw_pick()
	print("FW|①识别|目标=%s｜换谁=%d｜落点=%s" % [
		_target_name(), int(battle._finish_withdraw_idx), str(battle._finish_withdraw_cell)])
	print("FW|①诊断|合法落点=%s｜选人=%s｜我方(已出手, 原地够得到, 一击必杀)：%s" % [
		str(battle._sub_legal_cells_for_ai()), str(battle._finish_kill_hero_pick(hurt)),
		_gate_txt(hurt)])
	var dead0 := int(battle.enemy_dead)
	await battle._ai_finish_withdraw_apply()
	for i in 10:
		await get_tree().process_frame
	print("FW|①撤下后|我方阵亡 %d→%d｜对手场上=%d｜待补=%d｜场上敌方=%s｜替补席=%s｜全盘=%s" % [
		dead0, int(battle.enemy_dead), battle._foe_alive_count(), int(battle._pending_enemy_sub),
		_enemy_units(), str(battle.enemy_roster), _all_units()])
	print("FW|①补的那一手|步数=%d｜内容=%s" % [battle._ai_plan.size(), _plan_txt()])
	print("FW|①收尾检查|目标还在场上吗=%s｜对手场上=%d｜全盘=%s" % [
		str(_target_alive(hurt)), battle._foe_alive_count(), _all_units()])

func _arm_guard_multi() -> void:
	await _fresh(2)                        # 对手场上三个单位 ⇒ 不满足"只剩 1 个"
	battle._ai_finish_withdraw_pick()
	print("FW|②护栏A(对手不止1个)|目标=%s｜索引=%d（期望 -1）" % [
		_target_name(), int(battle._finish_withdraw_idx)])

func _arm_guard_reachable() -> void:
	await _fresh(0)
	# 把一个**还没出手**的我方单位挪到目标**原地就够得到**的格子（巨剑 射程 2）⇒ 这一回合本来就收得掉。
	#   ⚠️ 不能顺手把 `attacked_this_turn` 置 true：那等于"它这回合已经出手了"，
	#   护栏本来就该放它过去（已出手的单位不在"还收得掉"的名单里）—— 那样测的是另一件事。
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.hero_id == "hero_12":
			u.cell = Vector2i(1, 2)
			u.position = battle.grid.cell_to_world(u.cell)
			break
	for i in 2:
		await get_tree().process_frame
	print("FW|③摆盘|敌方=%s｜目标=%s" % [_enemy_units(), _target_name()])
	battle._ai_finish_withdraw_pick()
	print("FW|③护栏B(有人够得到)|目标=%s｜索引=%d（期望 -1）" % [
		_target_name(), int(battle._finish_withdraw_idx)])

func _target_alive(u: Unit) -> bool:
	return u != null and is_instance_valid(u) and u.alive

func _find_enemy(hid: String) -> Unit:
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY \
				and u.hero_id == hid:
			return u
	return null

func _target_name() -> String:
	var t = battle._finish_withdraw_target
	if t == null or not is_instance_valid(t):
		return "（无）"
	return "%s@%s 血=%d" % [str(t.display_name), str(t.cell), int(t.hp)]

func _enemy_units() -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			bits.append("%s@%s" % [str(u.display_name), str(u.cell)])
	return "／".join(bits) if bits.size() > 0 else "（无）"

func _all_units() -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u == null or not is_instance_valid(u):
			continue
		bits.append("%s(fn=%d,cell=%s,活=%s)" % [
			str(u.display_name), int(u.faction), str(u.cell), str(u.alive)])
	bits.append("units=%d" % battle.units.size())
	return "／".join(bits) if bits.size() > 0 else "（空）"

func _gate_txt(tgt: Unit) -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		if u.faction != DataRegistry.Faction.ENEMY:
			continue
		bits.append("%s@%s(已出手=%s, 够得到=%s, 必杀=%s)" % [
			str(u.display_name), str(u.cell), str(u.attacked_this_turn),
			str(battle._can_hit_unit(u, tgt)), str(battle._unit_one_shot(u, tgt))])
	return "／".join(bits) if bits.size() > 0 else "（无我方单位）"

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
