extends Node
## 【2026-10-02·一次性探针·只读】用户问：「**小阴影为什么没考虑到"暗域跑到 2,4 把小阴影位移出来、
##   然后小阴影会被造成巨量伤害"的场景**」（他那局：小阴影 只走到 (3,3)，日志只写「会挨 3 伤
##   （毒蛇淑女1＋嬉皮死神2）」、**连"⚠️ 被位移后"那行都没有**）。
##
## 盘面 = 用户那份 [战局转储]、按**计划执行完之后**的位置摆（界面口径 − 1 = 内部 0 基）：
##   AI（ENEMY）：宿魂 hero_46@(4,4) · **小阴影 hero_15@(3,3)** · 塔盾 hero_11@(3,2)[带 `<嘲讽>`]
##   玩家（PLAYER）：毒蛇淑女 hero_03@(2,4) · **暗域 hero_27@(4,3)**（攻3 移3 射1）· 嬉皮死神 hero_30@(3,4)
##
## 本探针把"暗域到底能不能换到小阴影"逐格拆开：
##   ① 小阴影 的每一格邻格：谁占着 / 暗域 走不走得到 / 从那儿打不打得到小阴影 / **嘲讽门放不放行**；
##   ② `_threat_can_hit()`（挨打合计那道门）与 `_displace_landing_cells()`（换位落点）各自的结论；
##   ③ 每个落点的"挨打合计 + 逐笔"、以及原地那一格 —— 看有没有"落到某处会挨巨量"的账被漏掉。
## 输出：XS|… / XS|END

const SK := "hero_15"     # 小阴影（被评估的那个）
const DK := "hero_27"     # 暗域（换位者）
const TD := "hero_11"     # 塔盾（带 <嘲讽>）

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
	await _rebuild()
	GameState.ai_difficulty = 3
	_spawn("hero_46", DataRegistry.Faction.ENEMY, Vector2i(4, 4), 19)   # 宿魂
	_spawn(SK, DataRegistry.Faction.ENEMY, Vector2i(3, 3), 18)          # 小阴影（计划里的落点）
	_spawn(TD, DataRegistry.Faction.ENEMY, Vector2i(3, 2), 40)          # 塔盾
	_spawn("hero_03", DataRegistry.Faction.PLAYER, Vector2i(2, 4), 21)  # 毒蛇淑女
	_spawn(DK, DataRegistry.Faction.PLAYER, Vector2i(4, 3), 20)         # 暗域
	_spawn("hero_30", DataRegistry.Faction.PLAYER, Vector2i(3, 4), 20)  # 嬉皮死神
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("XS|拿不到 AI")
		print("XS|END")
		get_tree().quit(0)
	ai.difficulty = GameState.ai_difficulty
	ai.log_decisions = false
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var sk = null
	var dk = null
	var td = null
	for u in sim.units:
		if u.hero_id == SK:
			sk = u
		elif u.hero_id == DK:
			dk = u
		elif u.hero_id == TD:
			td = u
	print("XS|盘面|小阴影@%s（血%d）｜暗域@%s（攻%d 移%d 射%d，与小阴影格距 %d）｜塔盾@%s（有<嘲讽>=%s）" % [
		str(sk.cell), int(sk.hp), str(dk.cell), int(dk.eatk), int(dk.emove), int(dk.atk_range),
		battle.grid.distance(dk.cell, sk.cell), str(td.cell),
		str((td.skills as Array).has(DataRegistry.Skill.TAUNT))])
	print("XS|结论①|挨打合计那道门 `_threat_can_hit(暗域→小阴影那一格)` = **%s**" % [
		str(ai._threat_can_hit(sim, dk, sk.cell, sk))])
	# 小阴影的每一格邻格逐条拆：谁占着 / 暗域能不能站上去 / 从那儿打不打得到 / 嘲讽门放不放行
	var walk: Array = ai._sim_walk_cells(sim, dk.cell, ai._threat_emove_next(sim, dk),
		(dk.skills as Array).has(DataRegistry.Skill.INFILTRATE))
	for f in battle.grid.neighbors(sk.cell):
		if not battle.grid.in_bounds(f):
			continue
		var holder := "空"
		if sim.occ.has(f):
			var h = sim.occ[f]
			holder = String(h.name) if h != null else "?"
		elif f == dk.cell:
			holder = "暗域自己"
		var in_range: bool = ai._cell_in_range(sim, dk, f, sk.cell)
		var taunt_ok: bool = ai._taunt_allows(sim, dk, sk, f)
		var can_stand: bool = (f == dk.cell) or walk.has(f)
		print("XS|逐格|%s｜占位=%s｜暗域能站=%s｜打得到小阴影=%s｜嘲讽放行=%s ⇒ %s" % [
			str(f), holder, str(can_stand), str(in_range), str(taunt_ok),
			("**这一格能换**" if (can_stand and in_range and taunt_ok) else
				("被嘲讽门挡下（站这儿会先打到塔盾）" if (can_stand and in_range) else
					("暗域站不到这儿" if not can_stand else "射程/视线不够")))])
	var lands: Array = ai._displace_landing_cells(sim, sk, sk.cell)
	var base := {}
	var base_v: float = ai._incoming_total_on(sim, sk, sk.cell, base, false, true)
	print("XS|结论②|换位落点 `_displace_landing_cells` = %s（%d 个）" % [
		str(lands).replace(" ", ""), lands.size()])
	var bt: Array[String] = []
	for row in (base.get("parts", []) as Array):
		var r: Array = row
		bt.append("%s%.1f" % [String(r[0]), float(r[1])])
	print("XS|原地|挨打合计 %.1f（%s）" % [base_v, ("＋".join(bt) if bt.size() > 0 else "没人够得到")])
	for c in lands:
		var o := {}
		var v: float = ai._incoming_total_on(sim, sk, c, o, false, true)
		var pt: Array[String] = []
		for row in (o.get("parts", []) as Array):
			var r: Array = row
			pt.append("%s%.1f" % [String(r[0]), float(r[1])])
		print("XS|落点|%s ⇒ 挨打合计 **%.1f**（%s）%s" % [str(c), v,
			("＋".join(pt) if pt.size() > 0 else "没人够得到"),
			"　⚠️ 这一格**孤立**（没有队友相邻）" if ai._sim_isolated_at(sim, sk, c) else ""])
	print("XS|★判定★|%s" % (
		"暗域**根本换不到小阴影**（能开的火位都被嘲讽门挡下 / 站不到）⇒ 日志里没有『被位移后』那行是**对的**"
		if lands.is_empty() else
		"换位落点有 %d 个 ⇒ 账里应当出现『被位移到 …』或『⚠️ 被位移后：…』" % lands.size()))
	print("XS|———|第二盘：把毒蛇淑女**从盘上拿掉**（= 用户说的「毒蛇先走开、把 (2,4) 让给暗域」）")
	await _arm_snake_gone()
	print("XS|END")
	get_tree().quit(0)

## 第二盘：毒蛇不在 (2,4) 了 ⇒ 那一格空出来 ⇒ 看暗域**能不能**从那儿换位、以及小阴影落到 (2,4) 会挨多少。
func _arm_snake_gone() -> void:
	await _rebuild()
	GameState.ai_difficulty = 3
	_spawn("hero_46", DataRegistry.Faction.ENEMY, Vector2i(4, 4), 19)
	_spawn(SK, DataRegistry.Faction.ENEMY, Vector2i(3, 3), 18)
	_spawn(TD, DataRegistry.Faction.ENEMY, Vector2i(3, 2), 40)
	_spawn(DK, DataRegistry.Faction.PLAYER, Vector2i(4, 3), 20)
	_spawn("hero_30", DataRegistry.Faction.PLAYER, Vector2i(3, 4), 20)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var snap := BattleSnapshot.collect(battle)
	var ai = battle._make_battle_ai()
	if ai == null:
		print("XS|二盘|拿不到 AI")
		return
	ai.difficulty = GameState.ai_difficulty
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
		snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
		snap.get("buff_owner", {}), snap.get("deads", {}))
	var sk = null
	var dk = null
	for u in sim.units:
		if u.hero_id == SK:
			sk = u
		elif u.hero_id == DK:
			dk = u
	print("XS|二盘·盘面|(2,4) 现在=%s｜暗域@%s 与小阴影格距 %d" % [
		("空" if not sim.occ.has(Vector2i(2, 4)) else "被占"), str(dk.cell),
		battle.grid.distance(dk.cell, sk.cell)])
	print("XS|二盘|从 (2,4) 开火：打得到小阴影=%s｜嘲讽放行=%s｜`_threat_can_hit`=%s" % [
		str(ai._cell_in_range(sim, dk, Vector2i(2, 4), sk.cell)),
		str(ai._taunt_allows(sim, dk, sk, Vector2i(2, 4))),
		str(ai._threat_can_hit(sim, dk, sk.cell, sk))])
	var lands: Array = ai._displace_landing_cells(sim, sk, sk.cell)
	print("XS|二盘|换位落点 = %s（%d 个）" % [str(lands).replace(" ", ""), lands.size()])
	for c in [Vector2i(2, 4), sk.cell]:
		var o := {}
		var v: float = ai._incoming_total_on(sim, sk, c, o, false, true)
		var pt: Array[String] = []
		for row in (o.get("parts", []) as Array):
			var r: Array = row
			pt.append("%s%.1f" % [String(r[0]), float(r[1])])
		print("XS|二盘|小阴影若在 %s（界面口径 %s）⇒ 挨打合计 **%.1f**（%s）%s" % [
			DataRegistry.cell_txt(c), str(c), v, ("＋".join(pt) if pt.size() > 0 else "没人够得到"),
			"　⚠️ 孤立（嬉皮死神会 ×2）" if ai._sim_isolated_at(sim, sk, c, dk) else ""])

func _spawn(hid: String, fn, cell: Vector2i, hp: int = 0):
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		if hp > 0:
			u.hp = hp
	return u

func _rebuild() -> void:
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
