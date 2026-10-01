extends Node
## 【2026-10-01·用户「你修完之后复刻复刻这个局面，看看解决没有」】**复刻用户实机那一局**。
##
## 局面来源（用户贴的 `[战局转储]` + 撤人日志，坐标已 −1 换成 0 基）：
##   玩家方（已阵亡 **1** 名）：hero_14(古拉博士)@(2,5) 血 **3** · hero_15(小阴影)@(4,6) 血 **6**
##     （转储里古拉博士是 hp5，判 ④ 时已被打到 3 —— 这里直接摆成 3）
##   我方：hero_46(宿魂)@(3,3) · hero_10(白游侠)@(4,4) · hero_48(装甲堡垒)@(3,2)，均已出手
##   障碍：(2,4)、(2,3)　｜ 动态替补池（配方档、无预设席）　｜ 我方阵亡 0 名
##
## **那一局的账**（为什么"正确行为是不撤"）：
##   玩家已死 1、场上 2 个 ⇒ 要赢还得收 **2** 个；古拉博士血 3 一刀能收 ✓，
##   可小阴影血 **6** 而替补池里最高一击是影丸 **5** ⇒ 它要 **2 刀**（削 5 + 收 1）
##   ⇒ 一共要 **3 刀** ⇒ 需要撤 **3** 次，而本回合最多只能撤 **2** 次 ⇒ **这一局收不掉**
##   ⇒ 第 1 轮撤一个只是在"白送自己一个阵亡"（用户原话正是「不能斩杀别撤人」）。
##
## 两个臂：
##   A = 原局面（我方 0 阵亡）⇒ **期望不撤**（硬门按"能收掉的目标数"拦住）
##   B = 对照：玩家已死 2 名 ⇒ 再收 1 个就赢 ⇒ **期望撤**（且只收一刀就够）

const WEIGHTS := "res://RL/weights/噩梦.json"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	print("R|CFG|复刻用户实机局面（2026-10-01 那局：古拉博士 3 血 + 小阴影 6 血，玩家已死 1）")
	await _arm("A 原局面·玩家已死1名（收不掉这一局 ⇒ 期望不撤）", 1)
	await _arm("B 对照·玩家已死2名（再收1个就赢 ⇒ 期望撤）", 2)
	await _arm_c()
	print("R|END")

func _arm(nm: String, pdead: int) -> void:
	await _fresh()
	GameState.enemy_recipe = { "dynamic_bench": true }
	battle.enemy_roster = []
	GameState.no_death_limit = false
	battle.player_dead = pdead
	battle.enemy_dead = 0
	battle._finish_withdraw_used = 0
	# 障碍（转储里那两块）
	battle.obstacles[Vector2i(2, 4)] = true
	battle.obstacles[Vector2i(2, 3)] = true
	# 玩家方：古拉博士 3 血、小阴影 6 血
	var t1 := _spawn("hero_14", DataRegistry.Faction.PLAYER, Vector2i(2, 5))
	if t1 != null:
		t1.hp = 3
	var t2 := _spawn("hero_15", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	if t2 != null:
		t2.hp = 6
	# 我方：宿魂 / 白游侠 / 装甲堡垒，均已出手（正好是"该被撤的那批"）
	for spec in [["hero_46", Vector2i(3, 3)], ["hero_10", Vector2i(4, 4)], ["hero_48", Vector2i(3, 2)]]:
		var mu := _spawn(String(spec[0]), DataRegistry.Faction.ENEMY, spec[1])
		if mu != null:
			mu.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	var max_atk := 0
	for hid in battle._dynamic_sub_candidates():
		var d = DataRegistry.get_hero(String(hid))
		if d != null:
			max_atk = maxi(max_atk, int(d.atk))
	print("R|%s|玩家血=3,6 ｜ 池里最高面板攻=%d ⇒ 3 能一刀收、6 要两刀 ｜ 玩家已死=%d、我方已死=0 ⇒ 可撤 %d 次" % [
		nm, max_atk, pdead, battle._finish_gate_mult()])
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	var who := ""
	if decided:
		var v := battle._finish_withdraw_victim_unit
		who = "%s→%s 落%s" % [
			(str(v.display_name) if (v != null and is_instance_valid(v)) else "?"),
			String(battle._finish_withdraw_hero), str(battle._finish_withdraw_cell)]
	print("R|%s|⇒ **%s**%s" % [nm, ("撤：" + who) if decided else "不撤", ""])
	if pdead == 1:
		print("R|判读|%s" % ("PASS（收不掉这一局 ⇒ 正确行为是不撤）" if not decided else "FAIL（不该撤却撤了）"))
	else:
		print("R|判读|%s" % ("PASS（再收 1 个就赢 ⇒ 该撤）" if decided else "FAIL（该撤却没撤）"))

## 【2026-10-01·用户暴怒那一局】AI **一个都没死**、玩家已死 1、场上红帽 6 血 + 古拉博士 1 血
##   ⇒ 能收掉 2 个 ⇒ 玩家死 3 ⇒ **赢** ⇒ **期望撤**（修前用面板攻估算判成"收不掉"✗）。
func _arm_c() -> void:
	await _fresh()
	GameState.enemy_recipe = { "dynamic_bench": true }   # 动态池（41 人，里面有太阳斩那类登场上 6 伤的）
	battle.enemy_roster = []
	GameState.no_death_limit = false
	battle.player_dead = 1
	battle.enemy_dead = 0          # ★ AI 一个都没死 ⇒ 本回合能撤 2 次
	battle._finish_withdraw_used = 0
	battle.obstacles[Vector2i(2, 3)] = true
	var t1 := _spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(0, 3))   # 红帽 6 血
	if t1 != null:
		t1.hp = 6
	var t2 := _spawn("hero_14", DataRegistry.Faction.PLAYER, Vector2i(3, 4))   # 古拉博士 1 血
	if t2 != null:
		t2.hp = 1
	for spec in [["hero_04", Vector2i(3, 2)], ["hero_09", Vector2i(4, 3)], ["hero_49", Vector2i(4, 2)]]:
		var mu := _spawn(String(spec[0]), DataRegistry.Faction.ENEMY, spec[1])
		if mu != null:
			mu.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	print("R|C 暴怒那局·AI 0 阵亡/玩家已死1/红帽6血+古拉博士1血|可撤 %d 次" % battle._finish_gate_mult())
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	var who := ""
	if decided:
		var v := battle._finish_withdraw_victim_unit
		who = "%s→%s 落%s" % [(str(v.display_name) if (v != null and is_instance_valid(v)) else "?"),
			String(battle._finish_withdraw_hero), str(battle._finish_withdraw_cell)]
	print("R|C 暴怒那局|⇒ **%s**%s" % [("撤：" + who) if decided else "不撤", ""])
	print("R|判读|%s" % ("PASS（两个都能收 ⇒ 玩家死 3 ⇒ 该撤）" if decided else "FAIL（该撤却没撤，bug 还在）"))

func _fresh() -> void:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
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
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	return battle._spawn_unit(hid, faction, cell)
