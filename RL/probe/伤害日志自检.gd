extends Node
## 【2026-09-29 一次性探针·只读·用户点名】AI 日志里"这一刀多少伤"必须与**真实结算**同源。
##   起因（用户实机）：「赏金猎人打复仇者的伤害计算怎么有问题，3伤」+「被贴身是3伤吗？」
##   ⇒ 赏金猎人(hero_20) 的倍率技是"**远程**打带<嘲讽>的目标 ⇒ ×2"，而**远程被贴身**时
##     `Unit.effective_atk()` 把基础攻击压成 1；两者叠加后，这一刀只可能是 **6（站远打）** 或
##     **1（贴身打）**，**不可能是 3**。日志写 3 = 漏乘倍率技（`DamageModel.attack_mult`）。
##
## 本探针在同一盘面上量两次（只改"复仇者离枪手多远"）：
##   · 距离 2（站远开火）⇒ 期望新口径 ≈ 6、旧口径 3
##   · 距离 1（贴身，pinned）⇒ 期望新口径 ≈ 1（与旧口径同）
## 旧口径 = `_hit_after_target_mods(..., u.eatk)`（改前日志用的），新口径 = `_sim_hit_est()`（改后日志用的）。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await _fresh()
	# 距离 2：枪手 (2,1)、复仇者 (2,3)（无遮挡、各自不在对方贴身范围）
	await _measure("距离2·站远开火", Vector2i(2, 1), Vector2i(2, 3))
	# 距离 1：枪手 (2,2)、复仇者 (2,3) —— 远程被贴身（pinned）
	await _measure("距离1·贴身(pinned)", Vector2i(2, 2), Vector2i(2, 3))
	# 暗域换位落点（用户 2026-09-29 晚那一问）
	await _displace_case()
	# 首发部署"看对面"的思路日志（用户 2026-09-29 晚要求写出来）
	await _deploy_reasoning_case()
	print("DMG|END")
	get_tree().quit(0)

## 【2026-09-29 晚·用户「暗域在 1,6 怎么打到 3,3 的长剑？」】换位落点必须 = **暗域开火那一格**，
##   而不是它回合开始时站的那一格（它可能先走过去打）。这里把两把尺子并排打出来。
func _displace_case() -> void:
	await _fresh()
	var dark := battle._spawn_unit("hero_27", DataRegistry.Faction.PLAYER, Vector2i(1, 6))  # 暗域（换位）
	var vic := battle._spawn_unit("hero_10", DataRegistry.Faction.ENEMY, Vector2i(3, 3))    # 我方被换的那个
	for i in 3:
		await get_tree().process_frame
	if dark == null or vic == null:
		print("DMG|位移落点|摆盘失败")
		return
	var ai = battle._make_battle_ai()
	if ai == null:
		print("DMG|位移落点|拿不到 AI 实例")
		return
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var di: int = battle.units.find(dark)
	var vi: int = battle.units.find(vic)
	if di < 0 or vi < 0 or di >= sim.units.size() or vi >= sim.units.size():
		print("DMG|位移落点|模拟下标对不上")
		return
	var sd: RefCounted = sim.units[di]
	var sv: RefCounted = sim.units[vi]
	var lands: Array = ai._displace_landing_cells(sim, sv, Vector2i(3, 3))
	var fire: Vector2i = ai._threat_fire_cell(sim, sd, Vector2i(3, 3), sv)
	var can: bool = ai._threat_can_hit(sim, sd, Vector2i(3, 3), sv)
	print("DMG|位移落点|暗域@(1,6) 移动=%d 射程=%d｜目标@(3,3)｜格距=%d｜暗域够得到=%s｜**旧口径(它起点格)=(1, 6)**｜**新口径(它开火格)=%s**｜落点表=%s" % [
		int(sd.emove), int(sd.atk_range), battle.grid.distance(Vector2i(1, 6), Vector2i(3, 3)),
		str(can), str(fire), str(lands)])

## 【2026-09-29 晚·用户要求】首发部署"会根据玩家首发调整"的思路日志：直接调那两个只读打印函数，
##   把控制台将看到的样子打出来（不跑整段部署流程 ⇒ 只验格式与口径，不动任何判定）。
func _deploy_reasoning_case() -> void:
	await _fresh()
	# 造一个"玩家已上阵两人、敌方卡池 5 人"的静态局面（只喂给日志函数）
	var p1 := battle._spawn_unit("hero_23", DataRegistry.Faction.PLAYER, Vector2i(2, 3))   # 复仇者（带[嘲讽]）
	var p2 := battle._spawn_unit("hero_20", DataRegistry.Faction.PLAYER, Vector2i(1, 3))   # 赏金猎人
	for i in 2:
		await get_tree().process_frame
	battle.player_deployed = []
	if p1 != null:
		battle.player_deployed.append(String(p1.hero_id))
	if p2 != null:
		battle.player_deployed.append(String(p2.hero_id))
	battle.enemy_pool = ["hero_11", "hero_30", "hero_27", "hero_40", "hero_25"]
	battle._deploy_prev_player = []
	battle._deploy_prev_ctr = {}
	print("DMG|首发思路日志|--- 下面两行就是控制台会打出来的样子 ---")
	battle._deploy_log_reasoning_head()
	for hid in ["hero_30", "hero_27", "hero_40"]:
		print("DMG|首发思路日志|%-8s %s" % [String(hid), battle._deploy_counter_detail(String(hid))])

func _fresh() -> void:
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
	for i in 2:
		await get_tree().process_frame

func _measure(tag: String, gun_cell: Vector2i, tank_cell: Vector2i) -> void:
	await _fresh()
	var gun := battle._spawn_unit("hero_20", DataRegistry.Faction.ENEMY, gun_cell)   # 赏金猎人（远程）
	var tank := battle._spawn_unit("hero_23", DataRegistry.Faction.PLAYER, tank_cell) # 复仇者（带[嘲讽]）
	for i in 3:
		await get_tree().process_frame
	if gun == null or tank == null:
		print("DMG|%s|摆盘失败" % tag)
		return
	tank.remove_status(StatusDB.SHIELD)     # 开局随机掉落/加成可能给目标挂盾，先摘掉（不然 "盾挡掉整刀"）
	battle._sync_ranged_adjacent()          # 真实侧：远程被贴身 ⇒ 基础攻击压 1（`Unit.effective_atk()`）
	var ai = battle._make_battle_ai()
	if ai == null:
		print("DMG|%s|拿不到 AI 实例" % tag)
		return
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var gi: int = battle.units.find(gun)
	var ti: int = battle.units.find(tank)
	if gi < 0 or ti < 0 or gi >= sim.units.size() or ti >= sim.units.size():
		print("DMG|%s|模拟下标对不上（gi=%d ti=%d）" % [tag, gi, ti])
		return
	var su: RefCounted = sim.units[gi]
	var st: RefCounted = sim.units[ti]
	var raw: float = ai._hit_after_target_mods(sim, st, st.cell, float(su.eatk))   # 改前日志的算法
	var fixed: float = ai._sim_hit_est(sim, su, st)                                # 改后日志的算法
	var mult: int = ai._sim_mult(sim, su, st)
	print("DMG|%s|格距=%d｜枪手面板攻=%d 模拟eatk=%d｜目标带[嘲讽]=%s｜倍率=%d｜**旧口径=%.0f**｜**新口径=%.0f**" % [
		tag, battle.grid.distance(gun_cell, tank_cell), int(gun.effective_atk()), int(su.eatk),
		str(tank.skills.has(DataRegistry.Skill.TAUNT)), mult, raw, fixed])
