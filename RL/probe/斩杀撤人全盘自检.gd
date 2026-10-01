extends Node
## 【2026-09-29 一次性探针·只读·用户点名要求】**「主动撤人把对面最后一个人斩杀」全盘枚举**
##   用户原话：「你自己能不能跑一下测试。把所有可以主动撤人把对方最后一个人斩杀的情况都跑一下。
##   哪些没有斩杀你自己修一下啊，我就没成功过一次」
##
## 做法：每条局面都在**真 Battle** 上摆盘（棋盘 5×7：x 0..4、y 0..6；AI 出生格 =
## (1,0)(0,1)(2,1)(3,0)(4,1)，玩家出生格在 y=6），然后：
##   ① `_ai_finish_withdraw_pick()` 看它**该不该撤**（期望"撤"的局面：`_finish_withdraw_target != null`）；
##   ② 该撤的再 `await _ai_finish_withdraw_apply()`，跑完"撤下 → 替补落位 → 补那一手"，
##      检查**目标是不是真被收掉**（`目标还在=false`）。
## 每条打一行 `T|名字|期望|实际|PASS/FAIL`，末尾 `T|END` + 汇总。
##
## ⚠️ 探针自己的三个坑（都已经写进 helper，别再踩）：① 挪单位必须同步 `occupancy`；
##    ② `Main.tscn` 会自己摆上双方首发 ⇒ 先清场；③ 格子别越界（5×7）。

var battle: Battle
var _pass := 0
var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# ① 相邻换位（近战替补）
	await _case("S1 目标相邻·近战替补", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07", "hero_16", "hero_18"], 2, 0, false, false)
	# ② 目标在中场（出生区走+打够得到）
	await _case("S2 目标中场·出生区够得到", true, Vector2i(2, 3), 3, Vector2i(0, 0),
			["hero_40"], 2, 0, false, false)
	# ③ 目标缩在玩家深处，但**前方有本方墓碑格**
	await _case("S3 目标深处·有前方墓碑格", true, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_07"], 2, 0, false, true)
	# ④ 目标缩在玩家深处、没有墓碑、也没有相邻单位（替补走+射刚好够）
	await _case("S4 目标深处·只靠走+射够到", true, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_07"], 2, 0, false, false)
	# ⑤ 目标深处 + 替补腿短（移动2/射程1 ⇒ 够不到）⇒ **不该撤**（撤了也白撤）
	await _case("S5 目标太远·替补够不到（期望不撤）", false, Vector2i(2, 6), 3, Vector2i(0, 0),
			["hero_11"], 2, 0, false, false)
	# ⑥ 【2026-09-29 晚·口径放宽后】**对面已死 2 个 + 场上还剩 2 个、其中一个 3 血能被替补一刀收**
	#   ⇒ 该撤 + 真收掉（打死他场上任何一个都到判负线 3 ⇒ 直接赢，不必非等到"只剩 1 个"）。
	await _case("S6 对面还剩2人·其中一个能收（期望撤+收掉）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1)
	# ⑦ 我方已死 2 个 ⇒ 不该撤（再撤就是丢第 3 个判负）
	await _case("S7 我方已死2（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 2, false, false)
	# ⑧ ③ 门：我方有人**站着就能一击打死**它 ⇒ 不该撤（直接普攻收）
	await _case("S8 有人站着能一发收（期望不撤）", false, Vector2i(2, 3), 1, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false)
	# ⑨ ③ 门：我方有个单位**站着就够得到**它（紧邻），但**它这一刀打不死**（塔盾 1 攻 vs 目标 5 血）
	#   ⇒ 仍该撤：靠替补（红帽 5 攻）一刀收掉。这一条才是"够得到但打不死"的正确测法。
	await _case("S9 够得到但打不死（期望仍撤·靠替补收）", true, Vector2i(2, 3), 5, Vector2i(2, 2),
			["hero_40", "hero_18", "hero_07"], 2, 0, false, false)
	# ⑩ 远程替补落到被撤下那一格（贴身 ⇒ 射程/伤害被压）⇒ 走一步再打仍应收掉
	await _case("S10 远程替补贴脸（走一步再打）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, true, false)
	# ⑪ 目标带 [圣盾] ⇒ 一刀收不掉 ⇒ 不该撤
	await _case("S11 目标带圣盾（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 0, true)
	# ⑫ 已有一个待补名额没落位 ⇒ 不该撤（别把两个挤在一拍里）
	await _case("S12 已有待补名额（期望不撤）", false, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 0, false, 1)
	# ⑬ 配方档：没有预设替补席、走**动态替补池** ⇒ 仍该撤 + 收掉
	await _case("S13 配方档·无预设席（动态池）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			[], 2, 0, false, false, 0, false, 0, true)
	# ⑭ 【用户那张图的现场】对面已死 2 个、场上还剩 2 个，其中一个**只有 2 血**、我方两个单位都够不到
	#   它（都在 (4,5)/(4,6) 那一角）⇒ 该撤 + 靠替补从出生区走过去一刀收掉。
	await _case("S14 对手2血·我方够不到（期望撤+收掉）", true, Vector2i(2, 2), 2, Vector2i(4, 5),
			["hero_40"], 2, 0, false, false, 1)
	# ⑮ 放宽之后**不能**变成"见谁都撤"：对面 2 个、谁都收不掉（目标 20 血、替补影丸只有 1 攻）⇒ 不撤
	await _case("S15 对手都收不掉（期望不撤）", false, Vector2i(2, 3), 20, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1)
	# ⑯ 对面只死 1 个（**没到赛点**）⇒ 不撤（撤下 = 白送自己一个阵亡）
	await _case("S16 对面只死1个·非赛点（期望不撤）", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1)
	# ⑰ 对面已死 2 个、场上 2 个，但**我方站着就能一发收掉**其中一个（1 血、贴着 (4,6)）
	#   ⇒ 不撤（计划自己就会赢，没必要送一个阵亡）
	await _case("S17 本回合有人能一发收（期望不撤）", false, Vector2i(2, 3), 20, Vector2i(2, 2),
			["hero_07"], 2, 0, false, false, 1, false, 0, false, 1, Vector2i(4, 5))
	# ⑱ **无死限局（自由部署测试）不能跟着放宽**：那边判"对面还有没有人可上"，打死一个不算赢
	#   ⇒ 对面还有 2 个时不撤（放宽只对死限局生效）
	await _case("S18 无死限局·对面还剩2个（期望不撤）", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 1, false, 0, false, 0, Vector2i(-99, -99), true)
	# ⑲ 无死限局 + 对面场上就剩这 1 个（且他没牌可上了）⇒ 打死他就是赢 ⇒ 照旧撤 + 收掉
	await _case("S19 无死限局·对面只剩1个（期望撤+收掉）", true, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), true)
	# ⑳ 【用户 2026-09-29 晚的现场】"**本回合被打死了 2 个，剩最后一个**"：判定挪到计划回放**之后**跑，
	#   此刻我方该出手的都出手完了（`attacked_this_turn = true`）、对面只剩这 1 个 ⇒ 该撤 + 一刀收掉。
	#   （①②两道门这时读到的 `player_dead` 才是这一回合打完的真实数字。）
	await _case("S20 本回合刚打死两个·只剩最后1个（期望撤+收掉）", true, Vector2i(2, 3), 3, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false, 0, false, 0, false, 0, Vector2i(-99, -99), false, true)
	# ---- 【2026-10-01·用户口径】"不是每回合都试着斩杀"的那道门槛（`_finish_hp_gate_ok()`）----
	#   用户订正口径（三档都是**小于等于**）：「0 名是小于等于 9 · 1 名是小于等于 6」；
	#   加上原来的「已死 2 人 ⇒ 单个最低血 ≤ 8」= 前 `3 − player_dead` 个之和 ≤ `[9, 6, 9]`。
	# S21 对面已死 2 名、场上这 1 个 19 血（> 9）⇒ **门槛拦住**，不撤。
	await _case("S21 已死2名·单个血19（>9）⇒ 门槛拦住", false, Vector2i(2, 3), 19, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false)
	# S22 对面已死 2 名、场上这 1 个 8 血（= 用户口径的上界 ≤8，也 ≤9）⇒ 门槛放行，但 8 血红帽（5 攻）收不掉
	#   ⇒ 仍不撤（**这一条的期望是"不撤"**：它验的是"门槛不再是拦路的那道门"）。
	await _case("S22 已死2名·单个血8（门槛放行，但5攻收不掉）", false, Vector2i(2, 3), 8, Vector2i(2, 2),
			["hero_40"], 2, 0, false, false)
	# S23 对面已死 1 名、场上 2 个（2 血 + 满血 33）⇒ 两个最低之和 = 35 > 6 ⇒ 门槛拦住。
	await _case("S23 已死1名·两个最低之和35（>6）⇒ 门槛拦住", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1)
	# S24 对面已死 1 名、场上 2 个都残（2 + 3 = 5）⇒ 门槛放行 ⇒ 撤 + 收掉。
	await _case("S24 已死1名·两个最低之和5（≤6）⇒ 撤+收掉", true, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1, false, 0, false, 3)
	# S25 **边界**：已死 1 名、两个最低之和正好 = 6 ⇒ 按"小于等于"应当放行 ⇒ 撤 + 收掉（2 血目标红帽收得掉）。
	await _case("S25 已死1名·两个最低之和=6（边界·≤）⇒ 撤+收掉", true, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 1, 0, false, false, 1, false, 0, false, 4)
	# S26 **边界**：已死 0 名、场上 3 个（2 + 4 + 4 = 10 > 9）⇒ 门槛拦住。
	#   ⚠️ 探针的 `extra_hp` 把"额外对手"**统一压成同一个血**（`hero_05` 只有这一个旋钮）⇒ 想要
	#      "2+3+4 = 正好 9"这种组合做不到；这里就取 2+4+4 = 10 当"刚过界"的样本。
	await _case("S26 已死0名·三个最低之和=10（>9）⇒ 门槛拦住", false, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 0, false, false, 2, false, 0, false, 4)
	# S27 已死 0 名、三个都残（2 + 3 + 3 = 8 ≤ 9）⇒ 门槛放行 ⇒ 撤 + 收掉 2 血那个。
	await _case("S27 已死0名·三个最低之和=8（≤9）⇒ 撤+收掉", true, Vector2i(2, 3), 2, Vector2i(2, 2),
			["hero_40"], 0, 0, false, false, 2, false, 0, false, 3)
	print("T|END|PASS=%d FAIL=%d" % [_pass, _fail])
	get_tree().quit(0)

## 一条局面。[with_grave] = 在目标前一格立一座本方墓碑；[ranged] = 替补席换成远程影丸；
## [target_shield] = 目标带圣盾；[pending] = 预置待补名额；[extra_foe] = 玩家场上额外站几个人；
## [dynamic] = 走配方档（无预设席、动态替补池）；
## 【2026-09-29 晚追加】[extra_hp] > 0 = 把这些"额外的对手"血量压到这么多（0 = 满血）；
## [extra_cell] 给定时，第 1 个额外对手摆在这一格（默认 (0,6)、(0,5)…）。
## ⚠️ 口径已于 2026-09-29 晚放宽：**对面已死 2 个 ⇒ 打死他场上任何一个都算赢**，所以"场上还剩几个"
##   不再是拦门的条件（判负线是累计 3 名阵亡）。
func _case(nm: String, expect_kill: bool, tgt_cell: Vector2i, tgt_hp: int, victim_cell: Vector2i,
		bench: Array, pdead: int, edead: int, ranged: bool, with_grave: bool,
		extra_foe: int = 0, target_shield: bool = false, pending: int = 0, dynamic: bool = false,
		extra_hp: int = 0, extra_cell: Vector2i = Vector2i(-99, -99), nodelim: bool = false,
		all_acted: bool = false) -> void:
	var hurt := await _fresh()
	GameState.no_death_limit = nodelim
	if dynamic:
		GameState.enemy_recipe = { "dynamic_bench": true }
		battle.enemy_roster = []
	else:
		GameState.enemy_recipe = {}
		battle.enemy_roster = (["hero_07"] if ranged else bench).duplicate()
	if with_grave:
		battle.graves[Vector2i(2, 5)] = { "fn": DataRegistry.Faction.ENEMY, "hero": "hero_11" }
	battle.player_dead = pdead
	battle.enemy_dead = edead
	battle._pending_enemy_sub = pending
	# 玩家最后一人
	var tgt := _spawn("hero_10", DataRegistry.Faction.PLAYER, tgt_cell)
	tgt.hp = tgt_hp
	if target_shield:
		tgt.add_status(StatusDB.SHIELD)
	else:
		# ⚠️ 自带牌组里有**圣光(hero_22)**：它 `call_deferred()` 发的盾会飘到探针摆的目标身上 ⇒ 判据当场
		#    变成"一刀收不掉"（S12 曾因此打出过自相矛盾的结果）。没有点名要盾的局面先把盾摘干净。
		tgt.remove_status(StatusDB.SHIELD)
	for i in extra_foe:
		var ec: Vector2i = (extra_cell if extra_cell.x >= 0 else Vector2i(0, 6 - i))
		var ef := _spawn("hero_05", DataRegistry.Faction.PLAYER, ec)
		if ef != null and extra_hp > 0:
			ef.hp = extra_hp
	# 我方两名单位：先摆的那个是"要撤的人"（`_finish_withdraw_victim()` 会挑没出手的第一个）
	var victim := _spawn("hero_11", DataRegistry.Faction.ENEMY, victim_cell)
	_spawn("hero_12", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	# [all_acted] = 复刻"计划回放已经跑完"那一刻：我方该出手的都出手完了（判定现在挂在回放之后）
	if all_acted:
		for u in battle.units:
			if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
				u.attacked_this_turn = true
	for i in 3:
		await get_tree().process_frame
	var units0 := battle.units.size()
	battle._ai_finish_withdraw_pick()
	var decided := battle._finish_withdraw_target != null
	# ⚠️ 这几个字段要在**此刻**抄下来：apply 跑完会把自己清空（重置成 -99/-1/""）⇒ 之前读的是"被清空后"的值
	#   （S13 日志里出现过"决定撤=true 但 落点=(-99,-99)"这种自相矛盾的读法）。
	var picked_cell: Vector2i = battle._finish_withdraw_cell
	var picked_hero: String = battle._finish_withdraw_hero
	var picked_idx: int = battle._finish_withdraw_idx
	var killed := not (tgt != null and is_instance_valid(tgt) and tgt.alive)
	if decided:
		await battle._ai_finish_withdraw_apply()
		for i in 10:
			await get_tree().process_frame
		killed = not (tgt != null and is_instance_valid(tgt) and tgt.alive)
	# 判读：期望"该收掉"的局面 = 必须决定撤 + 真收掉；期望"不该撤"的局面 = 不能**真的撤掉**
	#   ⚠️ 注意：pick 阶段只看四道门，"已有待补名额"那道门在 apply 阶段才拦 ⇒ 这里判"有没有真的减员"。
	var ok := false
	if expect_kill:
		ok = decided and killed
	else:
		ok = not decided or (not killed and battle.units.size() >= units0)
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("T|%s|期望=%s|决定撤=%s|目标被收=%s|%s|撤谁=%s 落点=%s 换谁=%s(席次%d)" % [
		nm, ("撤+收掉" if expect_kill else "不撤"), str(decided), str(killed),
		("PASS" if ok else "FAIL"),
		(str(victim.display_name) if victim != null and is_instance_valid(victim) else "—"),
		str(picked_cell), picked_hero, picked_idx])
	GameState.enemy_recipe = {}

## 起一局干净盘面（清掉 Main.tscn 自带的首发与地形），只留探针自己摆的人
func _fresh() -> Unit:
	if battle != null and is_instance_valid(battle):
		battle.queue_free()
		for i in 4:
			await get_tree().process_frame
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	_clear()
	battle.player_roster = []
	battle.enemy_roster = []
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	return null

func _clear() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.graves.clear()
	battle.obstacles.clear()
	battle.bombs.clear()
	battle.enemy_dead = 0
	battle.player_dead = 0

func _spawn(hid: String, faction: int, cell: Vector2i) -> Unit:
	var u := battle._spawn_unit(hid, faction, cell)
	if u == null:
		print("T|WARN|spawn_failed|%s" % hid)
	return u
