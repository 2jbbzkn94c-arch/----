extends Node
## 【2026-09-30 一次性探针】复刻用户给的那一局，回答：
##   「AI 的替补席 4 人里，有没有人能**当回合杀掉玩家 11 血的红帽**（杀 = 玩家死满 3 个 = AI 赢）？」
## 局面（来自用户贴的战斗转储 + 日志）：
##   AI：赏金猎人@(0,2) 18/19 攻1 射程2 · 小阴影@(1,1) 7/18 攻3 射程1 · 涌电技师@(2,2) 27/27 攻0 射程1
##   玩家：装甲堡垒@(1,2) 15/36 攻1 射程1 · **红帽@(2,1) 11/13 攻5 射程1** · 猎颅者@(1,0) 14/17 攻3 射程1
##   障碍：(0,4)(0,3)(4,4)(4,3)｜无敌方墓碑｜AI 替补席：影丸(攻5 远程) 血锁 涌电技师 锤头鲨
## 量四件事：
##   ① `sub_kill_scan` 现役的判定结果（用户日志里是"空"）；
##   ② 每个替补在**每个合法落点**上对红帽的"结算后伤害"（`_adj_foe_hit_on`）；
##   ③ 涌电技师的**电击**那一笔（移动触发，打全场最低血）打谁、多少伤害；
##   ④ 结论：有没有人真能当回合收掉红帽。
## 输出：每行 `SK2|...`，末尾 `SK2|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 4:
		await get_tree().process_frame
	# 清掉开局自动上的单位，按用户局面重摆
	for u in battle.units.duplicate():
		if u != null and is_instance_valid(u):
			battle.units.erase(u)
			u.queue_free()
	for i in 3:
		await get_tree().process_frame
	battle.enemy_roster = ["hero_07", "hero_41", "hero_38", "hero_37"]
	battle.player_roster = []
	var ai_bh = _mk("hero_20", DataRegistry.Faction.ENEMY, Vector2i(0, 2), 18)
	var ai_sh = _mk("hero_15", DataRegistry.Faction.ENEMY, Vector2i(1, 1), 7)
	var ai_su = _mk("hero_38", DataRegistry.Faction.ENEMY, Vector2i(2, 2), 27)
	var pl_tank = _mk("hero_48", DataRegistry.Faction.PLAYER, Vector2i(1, 2), 15)
	var pl_red = _mk("hero_40", DataRegistry.Faction.PLAYER, Vector2i(2, 1), 11)
	var pl_hunt = _mk("hero_39", DataRegistry.Faction.PLAYER, Vector2i(1, 0), 14)
	for i in 3:
		await get_tree().process_frame
	print("SK2|摆盘|AI %s｜玩家 装甲堡垒%dhp 红帽%dhp 猎颅者%dhp" % [
		_side(DataRegistry.Faction.ENEMY), int(pl_tank.hp), int(pl_red.hp), int(pl_hunt.hp)])

	var pair := battle._sim_pair(ai_bh, pl_red)
	if pair.is_empty():
		print("SK2|FAIL|建不出模拟局面")
		get_tree().quit(1)
		return
	var ai = pair["ai"]
	var sim = pair["sim"]
	var cells: Array = battle._sub_legal_cells_for_ai()
	print("SK2|合法落点|%s" % str(cells))

	# ① 现役判定
	var scan: Dictionary = ai.sub_kill_scan(sim, battle.enemy_roster, cells)
	print("SK2|①现役 sub_kill_scan|%s" % ("空（= 一个都收不掉）" if scan.is_empty() else str(scan)))

	# ② 每个替补 × 每个落点 ⇒ 对红帽的结算后伤害 + 够不够得到
	var red_sim: RefCounted = sim.units[battle.units.find(pl_red)]
	print("SK2|②逐个试|红帽 need=%d 血｜当前最低血玩家 = %s（%d 血）" % [
		int(red_sim.hp), _lowest_name(sim, pl_red), _lowest_hp(sim)])
	for hid in battle.enemy_roster:
		var def = DataRegistry.get_hero(str(hid))
		if def == null:
			continue
		var reach: int = DataRegistry.spawn_move(def) + DataRegistry.spawn_attack_range(def)
		var bits: Array[String] = []
		var best_hit := -1.0
		var best_cell := Vector2i(-99, -99)
		for c_v in cells:
			var c: Vector2i = c_v
			var dist: int = ai.approach_dist(sim, c, red_sim.cell)
			if dist > reach:
				bits.append("%s(太远%d)" % [str(c), dist])
				continue
			var probe = ai._sub_probe_unit(str(hid), c)
			if probe == null:
				continue
			var hit: float = ai._adj_foe_hit_on(sim, red_sim, probe)
			if hit > best_hit:
				best_hit = hit
				best_cell = c
			bits.append("%s(伤%.1f)" % [str(c), hit])
		print("SK2|  %s|攻%d 射程%d 够得到=%d｜最优 伤%.1f @%s｜%s" % [
			str(hid), int(def.atk), int(def.attack_range), reach, best_hit, str(best_cell),
			"／".join(bits)])

	# ③ 涌电技师"移动"那一下的账（电击打全场最低血玩家）
	var su_sim: RefCounted = sim.units[battle.units.find(ai_su)]
	for c_v in cells:
		var c2: Vector2i = c_v
		var probe2 = ai._sub_probe_unit("hero_38", c2)
		if probe2 == null:
			continue
		print("SK2|③涌电技师@%s|移动技能伤害（打最低血玩家）=%.1f｜普攻对红帽=%.1f｜合计对红帽上限=%.1f" % [
			str(c2), ai._on_move_hit_on(sim, probe2, red_sim, c2),
			ai._adj_foe_hit_on(sim, red_sim, probe2),
			ai._on_move_hit_on(sim, probe2, red_sim, c2) + ai._adj_foe_hit_on(sim, red_sim, probe2)])
	print("SK2|③谁是最低血玩家|<%s %d血>｜涌电技师落地后 eatk=%d emove=%d" % [
		_lowest_name(sim, pl_red), _lowest_hp(sim), int(su_sim.eatk), int(su_sim.emove)])
	# ④ 我方现有 3 个单位各自对红帽能打多少（`_team_hit_pool` 的原料）+ 够不够得到
	print("SK2|④现有单位对红帽|%s" % _team_vs(sim, ai, red_sim))
	print("SK2|④team_hit_pool|sum=%.1f top=%.1f（`sub_kill_scan` 用的就是它）" % [
		ai._team_hit_pool(sim, red_sim)[0], ai._team_hit_pool(sim, red_sim)[1]])
	# ⑤ 假设影丸补进来（落点 (3,0)）：全队合计够不够 11
	for c_v in cells:
		var c3: Vector2i = c_v
		var probe3 = ai._sub_probe_unit("hero_07", c3)
		if probe3 == null:
			continue
		var sh: float = ai._adj_foe_hit_on(sim, red_sim, probe3)
		var team: float = ai._team_hit_pool(sim, red_sim)[0]
		print("SK2|⑤影丸@%s|它对红帽 %.1f ＋ 现有全队 %.1f = **%.1f**（需要 11）｜%s" % [
			str(c3), sh, team, sh + team,
			"够 ⇒ 该收" if sh + team >= 11.0 else "不够"])

	print("SK2|END")
	get_tree().quit(0)

## 逐个我方单位：够不够得到红帽（emove+射程）、以及 `_adj_foe_hit_on` 报的伤害
func _team_vs(sim, ai, red_sim) -> String:
	var bits: Array[String] = []
	for i in sim.units.size():
		var u: RefCounted = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var eff: int = int(u.emove) + int(u.atk_range)
		var dist: int = ai.approach_dist(sim, u.cell, red_sim.cell)
		var can_reach: bool = dist <= eff
		var hit: float = ai._adj_foe_hit_on(sim, red_sim, u) if can_reach else 0.0
		bits.append("%s@%s 攻%d 射程%d 移动%d(合计%d) 距红帽%d %s⇒ 伤%.1f%s" % [
			str(u.name), str(u.cell), int(u.eatk), int(u.atk_range), int(u.emove), eff, dist,
			"够得到" if can_reach else "够不到", hit,
			" ✓参与合力" if (can_reach and hit > 0.0) else " ✗不计入"])
	return "／".join(bits)

func _mk(hid: String, fn: int, cell: Vector2i, hp: int) -> Unit:
	var u = battle._spawn_unit(hid, fn, cell)
	u.hp = hp
	return u

func _side(fn: int) -> String:
	var bits: Array[String] = []
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == fn:
			bits.append("%s@%s %d血 攻%d" % [str(u.display_name), str(u.cell), int(u.hp), int(u.effective_atk())])
	return "／".join(bits)

func _lowest_name(sim, fallback: Unit) -> String:
	var best = null
	for x in sim.units:
		if x != null and x.alive and x.fn != DataRegistry.Faction.ENEMY:
			if best == null or int(x.hp) < int(best.hp):
				best = x
	return str(best.name) if best != null else str(fallback.display_name)

func _lowest_hp(sim) -> int:
	var best := 9999
	for x in sim.units:
		if x != null and x.alive and x.fn != DataRegistry.Faction.ENEMY:
			best = mini(best, int(x.hp))
	return best
