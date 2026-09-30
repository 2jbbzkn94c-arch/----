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
##   ③ 护栏 B（2026-09-29 口径已改）：我方有个单位**原地够得到**它、但**一击打不死** ⇒ **照样撤人**
## 输出：每行 `FW|...`，末尾 `FW|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _arm_trigger()
	await _arm_guard_multi()
	await _arm_guard_reachable()
	await _arm_far_hitter()
	await _arm_sandbox_out_of_reach()
	await _arm_sandbox_in_reach()
	await _arm_body_blocks_shot()
	await _arm_swap_in_place()
	await _arm_dynamic_bench()
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
	# ⚠️ 【本探针踩过的坑】Main.tscn 自己会把双方首发摆上盘（还有障碍/道具）⇒ 不清场的话走廊里站着
	#   看不见的「原始单位」、走位判据一律算成「走不到」（⑧ 那种深处局面必挂）。
	_clear()
	_clear_terrain()
	battle.player_roster = []
	battle.enemy_roster = ["hero_07"]
	battle._spawn_unit("hero_11", DataRegistry.Faction.ENEMY, Vector2i(0, 0))
	battle._spawn_unit("hero_12", DataRegistry.Faction.ENEMY, Vector2i(4, 6))   # ⚠️ 棋盘是 5×7（y 0..6）⇒ 原来写 (0,8) 是**越界格**（探针踩过）
	var hurt = battle._spawn_unit("hero_10", DataRegistry.Faction.PLAYER, Vector2i(2, 3))
	hurt.hp = 3
	if extra_players >= 1:
		battle._spawn_unit("hero_09", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	if extra_players >= 2:
		battle._spawn_unit("hero_05", DataRegistry.Faction.PLAYER, Vector2i(2, 6))
	battle.player_dead = 2          # 对手已死 2 个（台上这个就是它最后一个）
	battle.enemy_dead = 0           # 我自己一个没死 ⇒ 撤一个也才 1，离判负线 3 还远
	GameState.active_side = GameState.SIDE_ENEMY
	GameState.match_over = false   # 上一面板真打完一局会把全局置 true ⇒ apply 直接早退（探针踩过）
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	# ⚠️ 【2026-09-29 晚·探针自身的非确定性】这一族探针**不加这句就会时好时坏**：同一盘面两次跑出不同结论
	#   （⑦ 的直接调用一次返回 hero_07、一次返回空）。原因是**开局随机掉落/加成**可能给探针摆的目标挂上
	#   [圣盾] —— 而判据里 `_finish_pick_kills()` 明确要求 `not st.shield`（一次圣盾挡掉整刀）⇒ 那一跑就
	#   判成"收不掉"。这里把探针自己摆的人身上的圣盾一律摘掉（要测圣盾的局面在 `全盘自检` 的 S11 里点名测）。
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive:
			u.remove_status(StatusDB.SHIELD)
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
	print("FW|①apply前|state=%d|match_over=%s|待补=%d|索引=%d|目标活=%s" % [int(battle.state), str(GameState.match_over), int(battle._pending_enemy_sub), int(battle._finish_withdraw_idx), str(_target_alive(hurt))])
	await battle._ai_finish_withdraw_apply()
	for i in 10:
		await get_tree().process_frame
	print("FW|①撤下后|我方阵亡 %d→%d｜对手场上=%d｜待补=%d｜场上敌方=%s｜替补席=%s｜全盘=%s" % [
		dead0, int(battle.enemy_dead), battle._foe_alive_count(), int(battle._pending_enemy_sub),
		_enemy_units(), str(battle.enemy_roster), _all_units()])
	print("FW|①补的那一手|步数=%d｜内容=%s" % [battle._ai_plan.size(), _plan_txt()])
	print("FW|①收尾检查|目标还在场上吗=%s｜对手场上=%d｜全盘=%s" % [
		str(_target_alive(hurt)), battle._foe_alive_count(), _all_units()])

## 【2026-09-29 晚·口径放宽后】**这一格不再拦人**：死限局里"对面已死 2 个 ⇒ 打死他场上任何一个都算赢"，
##    所以对面还剩好几个也可能照撤（只要其中一个能被替补一刀收）。这一格现在的意义 = **看它撤的是谁**：
##    该挑"最容易收的"（血最少、替补够得到的那个），而不是死盯着某一个。
func _arm_guard_multi() -> void:
	await _fresh(2)                        # 对手场上三个单位（全部都满血 ⇒ 没人收得掉 ⇒ 仍然不撤）
	battle._ai_finish_withdraw_pick()
	print("FW|②放宽后(对面3人·其中一个3血)|目标=%s｜索引=%d（期望 0：死限局里打死谁都算赢 ⇒ 挑最脆的那个收；三个都满血才该不撤）" % [
		_target_name(), int(battle._finish_withdraw_idx)])

## ④ 【2026-09-29·用户实测追出来的】"有人一击能打死它"这半条判据**没要求够得到** —— 用户实测
##    「AI 会不会主动撤人斩杀我方第三个 ⇒ 好像没有这个行为」：只要我方**任意**单位的一击 ≥ 目标血
##    （残血目标几乎必然满足），旧代码就判"这一回合还收得掉"⇒ **不撤人**，哪怕那个单位在棋盘另一头。
##    这里用一个"一击够狠但离得远"的我方单位（影丸 5 攻，站 (7,7)）复现：修好之前 idx 应为 -1。
func _arm_far_hitter() -> void:
	var hurt := await _fresh(0)
	var far := battle._spawn_unit("hero_07", DataRegistry.Faction.ENEMY, Vector2i(7, 7))
	for i in 2:
		await get_tree().process_frame
	print("FW|④摆盘|敌方=%s｜目标 %s@%s 血=%d｜远处置拳手 %s@%s（一击=%.1f / 站着够得到=%s）" % [
		_enemy_units(), str(hurt.display_name), str(hurt.cell), int(hurt.hp),
		str(far.display_name), str(far.cell), battle._unit_hit_on(far, hurt), str(battle._can_hit_unit(far, hurt))])
	battle._ai_finish_withdraw_pick()
	print("FW|④远处置拳手（期望：照样撤人斩杀）|目标=%s｜索引=%d（期望 0）｜落点=%s" % [
		_target_name(), int(battle._finish_withdraw_idx), str(battle._finish_withdraw_cell)])

func _arm_guard_reachable() -> void:
	await _fresh(0)
	# 把一个**还没出手**的我方单位挪到目标**原地就够得到**的格子（巨剑 射程 2）⇒ 这一回合本来就收得掉。
	#   ⚠️ 不能顺手把 `attacked_this_turn` 置 true：那等于"它这回合已经出手了"，
	#   护栏本来就该放它过去（已出手的单位不在"还收得掉"的名单里）—— 那样测的是另一件事。
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.hero_id == "hero_12":
			_teleport(u, Vector2i(1, 2))
			break
	for i in 2:
		await get_tree().process_frame
	print("FW|③摆盘|敌方=%s｜目标=%s" % [_enemy_units(), _target_name()])
	battle._ai_finish_withdraw_pick()
	print("FW|③护栏B(只够得到·打不死)|目标=%s｜索引=%d（期望 0：新口径「够得到 **且** 能一击打死」才算收得掉）" % [
		_target_name(), int(battle._finish_withdraw_idx)])

## 清场：Main.tscn 会自己把双方首发摆上盘（还有障碍/道具）⇒ 不清掉的话走廊里站着"看不见的原始单位"、
##   走位判据一律算成"走不到"（⑧ 那种深处局面必挂）。只清实体，不动探针随后自己 spawn 的单位。
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

## 只清地形类实体（障碍 / 墓碑 / 炸弹）
func _clear_terrain() -> void:
	battle.obstacles.clear()
	battle.graves.clear()
	battle.bombs.clear()

## ⑤ 【2026-09-29·用户实测「自由部署模式还是不会主动撤人」】把**自由部署（测试）沙箱**的状态差异复刻出来：
##    `no_death_limit = true` + 替补席 5 人（沙箱就是"8 人队伍里没首发的都进替补席"），目标放在
##    **玩家半边深处** (2,6)。
##    ⚠️ 2026-09-29 晚：这一格的期望**从"不撤"变成"照撤"** —— ④ 门放宽成"从落点走 ≤ 移动力再开火"之后，
##    替补影丸从出生区 (2,1) 走出来就能打到 (2,6)（日志里的 `走+打距离=5 vs 上限=5`）⇒ 能收就该撤。
##    真正该"不撤"的是**超出走+射上限**的局面（见 `斩杀撤人全盘自检` 的 S5）。
func _arm_sandbox_out_of_reach() -> void:
	var hurt := await _fresh(0)
	GameState.no_death_limit = true
	battle.enemy_roster = ["hero_07", "hero_10", "hero_26", "hero_16", "hero_40"]
	battle.graves.clear()                       # 沙箱里 AI 一个没死过 ⇒ 没有前方墓碑格
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction != DataRegistry.Faction.ENEMY:
			_teleport(u, Vector2i(2, 6))
	for i in 2:
		await get_tree().process_frame
	print("FW|⑤沙箱样子·目标缩在玩家半边|目标 %s@%s 血=%d｜替补席=%d 人｜合法落点=%s" % [
		str(hurt.display_name), str(hurt.cell), int(hurt.hp), battle.enemy_roster.size(),
		str(battle._sub_legal_cells_for_ai())])
	battle._ai_finish_withdraw_pick()
	print("FW|⑤判定|索引=%d（期望 0：替补走 ≤ 出生移动力后够得到 (2,6) ⇒ 能收就撤；日志里有 走+打距离）" % int(battle._finish_withdraw_idx))

## ⑥ 同样的沙箱状态、只把目标挪回**AI 出生区够得到**的位置（(2,3)）⇒ 期望：**照撤**（证明沙箱配置本身不是拦路虎）
func _arm_sandbox_in_reach() -> void:
	GameState.no_death_limit = false
	var hurt := await _fresh(0)
	GameState.no_death_limit = true
	battle.enemy_roster = ["hero_07", "hero_10", "hero_26", "hero_16", "hero_40"]
	for i in 2:
		await get_tree().process_frame
	print("FW|⑥沙箱样子·目标在射程内|目标 %s@%s 血=%d｜替补席=%d 人" % [
		str(hurt.display_name), str(hurt.cell), int(hurt.hp), battle.enemy_roster.size()])
	battle._ai_finish_withdraw_pick()
	var v6 := battle._finish_withdraw_victim()
	print("FW|⑥诊断|替补席=%s｜合法落点=%s｜要撤的人=%s@%s｜选人(不摘)=%s｜选人(先摘)=%s" % [str(battle.enemy_roster), str(battle._sub_legal_cells_for_ai()), (str(v6.display_name) if v6 != null else "（无）"), (str(v6.cell) if v6 != null else "—"), str(battle._finish_kill_hero_pick(hurt)), str(battle._finish_kill_hero_pick(hurt, v6))])
	print("FW|⑥判定|索引=%d（期望 ≥0：沙箱配置本身不拦人；**选谁**不写死 —— 多个都能收时挑攻击力最低的，随候选池变化）｜落点=%s" % [int(battle._finish_withdraw_idx), str(battle._finish_withdraw_cell)])
	GameState.no_death_limit = false

## ⑦ 【2026-09-29·用户实测追问「是不是在检测能不能杀的路径时候，把准备替补换下的英雄也当障碍了」】
##    **对，就是这个**。摆一个只有这个变量不一样的局面：目标 (2,3) 血 3、替补影丸（射程 2）能从
##    (2,1) 打到它 —— 但**我方要撤的那个人正好站在 (2,2)**（= 弹道正中间，`_cell_in_range()` 的"身体"拦下）。
##    同一个局面、同一个落点，只比较"摘不摘掉要撤的人"：
##      · `_finish_kill_hero_pick(tgt)`            （旧口径：不摘）⇒ 期望 空
##      · `_finish_kill_hero_pick(tgt, victim)`    （新口径：先摘 ⇒ 与真实序列一致）⇒ 期望**选得出人**
##        （`idx` 非 -1 或 `hero` 非空；具体落点不写死 —— 多个候选都能收尾时会挑攻击力最低的那个）
func _arm_body_blocks_shot() -> void:
	var hurt := await _fresh(0)
	# 把先摆的那位（塔盾，`units` 里第一个 ⇒ 就是 `_finish_withdraw_victim()` 会挑的那个）挪到弹道中间
	var blocker: Unit = null
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			if blocker == null:
				blocker = u
			_teleport(u, Vector2i(2, 2))
			break
	for i in 2:
		await get_tree().process_frame
	var victim := battle._finish_withdraw_victim()
	var old_pick := battle._finish_kill_hero_pick(hurt)
	var new_pick := battle._finish_kill_hero_pick(hurt, victim)
	print("FW|⑦摆盘|目标 %s@%s 血=%d｜要撤的人 %s@%s｜我方=%s" % [
		str(hurt.display_name), str(hurt.cell), int(hurt.hp),
		(str(victim.display_name) if victim != null else "（无）"),
		(str(victim.cell) if victim != null else "—"), _enemy_units()])
	print("FW|⑦同一局面·只比「摘不摘要撤的人」|旧口径(不摘)=%s｜新口径(先摘)=%s" % [str(old_pick), str(new_pick)])
	battle._ai_finish_withdraw_pick()
	# ⚠️ 落点**不写死**：多个候选都能收尾时选人优先"攻击力最低"（把强英雄留给后面），同分才比落点 ⇒
	#   期望只能是"某个合法落点"，具体是哪一格随候选池变化（曾写死 (2,1)，后来变成 (1,0)）。
	print("FW|⑦整条判定|目标=%s｜索引=%d（期望 0）｜落点=%s（期望：任一合法落点，能一刀收掉即可）" % [
		_target_name(), int(battle._finish_withdraw_idx), str(battle._finish_withdraw_cell)])
	var units0 := battle.units.size()
	var roster0 := battle.enemy_roster.size()
	await battle._ai_finish_withdraw_apply()
	for i in 8:
		await get_tree().process_frame
	print("FW|⑦执行后|单位 %d→%d｜替补席 %d→%d｜目标还在=%s｜场上敌方=%s" % [
		units0, battle.units.size(), roster0, battle.enemy_roster.size(),
		str(_target_alive(hurt)), _enemy_units()])

func _target_alive(u) -> bool:   # 形参不标类型：撤下后传进来的可能是已释放实例（标了会报 Invalid type）   # 形参不标类型：撤下后传进来的可能是已释放实例（标了会报 Invalid type）
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

## ⑧ 【2026-09-29·第四轮·用户「你能不能别一会一个原因」】把"目标缩在玩家最深处"这个**真实局面**打通：
##    目标缩到玩家最深处 **(2,6)**（棋盘只有 5×7 ⇒ y 最大 6；曾误写成 (2,7) 那种盘外格），
##    但**我方有一个单位贴在它旁边 (2,5)** ——
##    把那一格也当合法落点（"撤下一个、顶上来的站他那一格"）⇒ 应该：撤掉旁边那个人、替补落在他那一格、
##    一刀收掉。期望：索引=0（落点不写死，见下）；执行后单位 −1、替补席 −1、目标被收掉。
func _arm_swap_in_place() -> void:
	var hurt := await _fresh(0)
	# 目标挪到玩家最深处；把"先摆的那位"（= `_finish_withdraw_victim()` 会挑的人）贴到它旁边
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction != DataRegistry.Faction.ENEMY:
			_teleport(u, Vector2i(2, 6))
	var mover: Unit = null
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			mover = u
			break
	if mover != null:
			_teleport(mover, Vector2i(2, 5))
	for i in 2:
		await get_tree().process_frame
	var cells8: Array = battle._sub_legal_cells_for_ai()
	print("FW|⑧摆盘（目标缩在玩家最深处·旁边有我方单位）|目标 %s@%s 血=%d｜要撤的人=%s@%s｜常规合法落点=%s（他那一格原来不在里面）" % [
		str(hurt.display_name), str(hurt.cell), int(hurt.hp),
		(str(mover.display_name) if mover != null else "（无）"), (str(mover.cell) if mover != null else "—"),
		str(cells8)])
	battle._ai_finish_withdraw_pick()
	# ⚠️ 落点不写死（理由同 ⑦）；这一格的意义是"**要撤的那个人那一格**也在合法落点里"（见上面的常规列表）。
	print("FW|⑧判定|目标=%s｜索引=%d（期望 0）｜落点=%s（期望：任一合法落点，能一刀收掉即可）" % [
		_target_name(), int(battle._finish_withdraw_idx), str(battle._finish_withdraw_cell)])
	var u0 := battle.units.size()
	var r0 := battle.enemy_roster.size()
	await battle._ai_finish_withdraw_apply()
	for i in 8:
		await get_tree().process_frame
	print("FW|⑧执行后|单位 %d→%d｜替补席 %d→%d｜目标还在=%s｜场上敌方=%s" % [
		u0, battle.units.size(), r0, battle.enemy_roster.size(), str(_target_alive(hurt)), _enemy_units()])

## ⑨ 【2026-09-29·用户问「噩梦难度没有预设替补位是不是也有影响」】**是**：配方档（`enemy_recipe`）走
##    动态替补时 `enemy_roster` 是空的 ⇒ 老写法在 ④ 的第一行就返回、整条链作废。这里复刻：
##    `enemy_recipe = {"dynamic_bench": true}` + `enemy_roster = []`，目标 (2,3) 血 3、旁边有我方单位
##    ⇒ 期望：**照样撤人 + 一刀收**（换的人从动态池里挑，落位也认这个指定人名）。
func _arm_dynamic_bench() -> void:
	var hurt := await _fresh(0)
	GameState.enemy_recipe = { "dynamic_bench": true }
	battle.enemy_roster = []
	var mover: Unit = null
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			mover = u
			break
	if mover != null:
		_teleport(mover, Vector2i(2, 2))
	for i in 2:
		await get_tree().process_frame
	print("FW|⑨摆盘（配方档·无预设替补席）|目标 %s@%s 血=%d｜预设席=%d 人｜动态替补=%s｜要撤的人=%s@%s" % [
		str(hurt.display_name), str(hurt.cell), int(hurt.hp), battle.enemy_roster.size(),
		str(battle._dynamic_sub_active()), (str(mover.display_name) if mover != null else "（无）"),
		(str(mover.cell) if mover != null else "—")])
	battle._ai_finish_withdraw_pick()
	print("FW|⑨判定|目标=%s｜换谁=%s（下标 %d）｜落点=%s（期望 索引 -1 但换谁非空）" % [
		_target_name(), str(battle._finish_withdraw_hero), int(battle._finish_withdraw_idx),
		str(battle._finish_withdraw_cell)])
	var u0 := battle.units.size()
	await battle._ai_finish_withdraw_apply()
	for i in 8:
		await get_tree().process_frame
	print("FW|⑨执行后|单位 %d→%d｜目标还在=%s｜场上敌方=%s" % [
		u0, battle.units.size(), str(_target_alive(hurt)), _enemy_units()])
	GameState.enemy_recipe = {}

## 挪一个单位到别的格子（**必须同时改 `occupancy`**：只改 `u.cell` 会让快照的 descs 与 occ 打架，
##   `walk_dist` 就会把路算成"走不到"——本探针第一版就栽在这，白判了一轮"④ 走不到"）。
func _teleport(u: Unit, cell: Vector2i) -> void:
	if u == null or not is_instance_valid(u):
		return
	if battle.occupancy.get(u.cell, null) == u:
		battle.occupancy.erase(u.cell)
	u.cell = cell
	u.position = battle.grid.cell_to_world(cell)
	battle.occupancy[cell] = u

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
