extends Node
## 【2026-10-01·一次性探针·只读·用户实机局面】「**AI 直接把我的红帽打到 4 血，对面是 2 个 3 攻和一个 2 攻复仇者。
##   我怀疑他考虑复仇者 4 伤反击**」
##   ⇒ 量"红帽站在某个位置时"两笔账：
##     · `_incoming_total_on()`（血线的输入）= 对手**主动打她**能打多少
##     · 她**自己出手**时，贴身的`复仇者(hero_23)` 会反击多少（= 攻 2 × 2 = 4）
##   再看这两笔加起来把她逼到什么血线附近。
##
## 盘面：AI 红帽(hero_40，血 13)@(3,4)｜玩家 复仇者(hero_23，攻2/嘲讽/反击无限×2)@(3,3)（贴身）
##   ＋ 玩家 两个 3 攻单位（鼠队长 hero_04、巨剑 hero_12）摆在不贴她的位置（复刻"2 个 3 攻 + 一个 2 攻复仇者"）。
##   跑四档血（13 / 7 / 5 / 4）看 `_incoming_total_on` 与"她自己出手会吃多少"两条线怎么变。
##
## 输出：RHP|摆盘 / RHP|血X … / RHP|结论 / RHP|END

const HP_SET := [13, 7, 5, 4]

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 3
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
	var red := _spawn("hero_40", DataRegistry.Faction.ENEMY, Vector2i(3, 4))   # 红帽
	var av := _spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 3))   # 复仇者（贴身）
	var a1 := _spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(1, 1))   # 3 攻（不贴她）
	var a2 := _spawn("hero_12", DataRegistry.Faction.PLAYER, Vector2i(4, 1))   # 3 攻（不贴她）
	battle.player_dead = 0
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	if red == null or av == null:
		print("RHP|拿不到单位"); get_tree().quit(0); return
	print("RHP|摆盘|红帽@%s 血%d ｜ 复仇者@%s 攻%d（反击×2=%d，格距 %d）｜ %s@%s 攻%d ｜ %s@%s 攻%d" % [
		DataRegistry.cell_txt(red.cell), int(red.hp), DataRegistry.cell_txt(av.cell),
		int(av.effective_atk()), int(av.effective_atk()) * 2,
		battle.grid.distance(red.cell, av.cell),
		_nm(a1), (DataRegistry.cell_txt(a1.cell) if a1 != null else "-"), (int(a1.effective_atk()) if a1 != null else 0),
		_nm(a2), (DataRegistry.cell_txt(a2.cell) if a2 != null else "-"), (int(a2.effective_atk()) if a2 != null else 0)])
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	# 【取证】把红帽那几档权重打开（生产档默认 0 = 关闭 ⇒ 不改生产行为），才能看到"血线"这一项的读数
	ai.w_redcap_hp_floor = 1.0
	ai.w_redcap_cheap_hp = 6.0
	for hp_v in HP_SET:
		red.hp = int(hp_v)
		var snap := BattleSnapshot.collect(battle)
		var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
		var ri := -1
		for i in sim.units.size():
			var u = sim.units[i]
			if u != null and String(u.hero_id) == "hero_40":
				ri = i
		if ri < 0:
			continue
		var su = sim.units[ri]
		var inc: Dictionary = {}
		var inc_all: float = ai._incoming_total_on(sim, su, su.cell, inc)
		# 她**自己出手**时，贴身复仇者的反击伤害（逐条照 `_sim_counter_check()` 的门）
		var cnt := 0.0
		for k in sim.units.size():
			var e = sim.units[k]
			if e == null or not e.alive or int(e.fn) == int(su.fn):
				continue
			if battle.grid.distance(e.cell, su.cell) != 1:
				continue
			if bool(e.stunned) or int(e.eatk) <= 0:
				continue
			if bool(e.counter_used) and String(e.hero_id) != "hero_23":
				continue
			var cb := 2 if (String(e.hero_id) == "hero_23" and not bool(e.silenced)) else 1
			cnt = maxf(cnt, float(int(e.eatk) * cb))
		var tot := inc_all + cnt
		var terms = ai._redcap_terms(sim)
		var floor_v := float((terms as Dictionary).get("血线", 0.0))
		print("RHP|血%-3d|对手主动打她=%.0f ｜ 她出手吃反击=%.0f ｜ **合计=%.0f** ｜ 会被打死=%s ｜ 血线项(权重1.0)=%.2f（挨打明细 %s）" % [
			int(hp_v), inc_all, cnt, tot, str(tot >= float(int(hp_v))), floor_v, str(inc.get("pos", []))])
	print("RHP|结论|血线的输入 `_incoming_total_on()` **只算对手主动打她**（复仇者只按 %d 计）⇒ 反击那一笔（%d）不在血线里。" % [
		int(av.effective_atk()), int(av.effective_atk()) * 2])
	print("RHP|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> Unit:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
	return u

func _nm(u) -> String:
	return (String(u.display_name) + ("(hero_" + String(u.hero_id).substr(5) + ")") if (u != null and is_instance_valid(u)) else "（无）")
