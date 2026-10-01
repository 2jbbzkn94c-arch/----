extends Node
## 【2026-10-01·一次性探针·只读·用户点名】「**红帽是不是没有考虑复仇者反击双倍的血线**」
##   把"红帽打复仇者会吃多少反击"在**真实**与**模拟**两侧各跑一遍，再看那两笔红帽账怎么读：
##     · `_incoming_total_on()`（① 血线 / ⑤ 止损 的输入）= "下回合**对手主动打她**能打多少"
##     · `_redcap_trade_gain()`（④ 蓄爆）= "她一出手会吃到多少反击（**含复仇者 ×2**）"
##
## 盘面：AI 红帽(hero_40，攻5/血13/死亡自爆13)@(2,3)｜玩家 复仇者(hero_23，攻2/嘲讽/反击无限×2)@(2,2)（贴身）
##   另摆一个"陪练"玩家单位（非嘲讽）供真实侧对照。
##
## 输出：RCC|CFG / RCC|真实 / RCC|模拟 / RCC|账 / RCC|判定 / RCC|END

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
	var red := _spawn("hero_40", DataRegistry.Faction.ENEMY, Vector2i(2, 3))
	var av := _spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(2, 2))
	_spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(0, 0))   # 陪练（非嘲讽，远处）
	battle.player_dead = 0
	battle.enemy_dead = 0
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	if red == null or av == null:
		print("RCC|拿不到单位"); get_tree().quit(0); return
	print("RCC|CFG|噩梦｜红帽 hp=%d atk=%d @%s ｜ 复仇者 hp=%d atk=%d 攻距=%d @%s（格距 %d）" % [
		int(red.hp), int(red.effective_atk()), DataRegistry.cell_txt(red.cell),
		int(av.hp), int(av.effective_atk()), int(av.attack_range), DataRegistry.cell_txt(av.cell),
		battle.grid.distance(red.cell, av.cell)])
	var hp0 := int(red.hp)
	# ---- 真实侧：直接调真实的**反击结算**（`_play_counter`），拿到同步读数 ----
	#   ⚠️ 不能走 `_do_attack()`：那条路是**动画驱动**的协程，反击在几段演出之后才结算
	#   （第一版探针因此读到"掉 0 点"的假象）。
	var dist := battle.grid.distance(red.cell, av.cell)
	await battle._play_counter(red, av, true, dist)
	# ⚠️ `_play_counter()` 是**动画串**：主门（`cdmg <= 0`）在里面同步判，但真正的掉血在
	#   **tween 回调**里 ⇒ 必须等演出跑完再读血（前两版分别读到"掉 0 点"就是没等够）。
	for i in 90:
		await get_tree().process_frame
		if not red.alive or int(red.hp) < hp0:
			break
	var lost_real := hp0 - (int(red.hp) if red.alive else 0)
	print("RCC|真实|红帽 hp %d → %s｜**掉 %d 点**（复仇者反击×2 = 攻 %d × 2）" % [
		hp0, (str(int(red.hp)) if red.alive else "阵亡"), lost_real, int(av.effective_atk())])
	# ---- 模拟侧：同一招在 AI 的模拟里掉多少 ----
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var ri := -1
	var ai_idx := -1
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null:
			continue
		if String(u.hero_id) == "hero_40":
			ri = i
		if String(u.hero_id) == "hero_23":
			ai_idx = i
	if ri < 0 or ai_idx < 0:
		print("RCC|模拟|下标找不到"); get_tree().quit(0); return
	var sim_hp0 := int(sim.units[ri].hp)
	ai._apply(sim, ri, { "move": null, "atk": ai_idx })
	print("RCC|模拟|红帽 hp %d → %d｜**掉 %d 点**" % [
		sim_hp0, int(sim.units[ri].hp), sim_hp0 - int(sim.units[ri].hp)])
	# ---- 红帽那几笔账 ----
	var terms = ai._redcap_terms(sim)
	print("RCC|账|`_redcap_terms` = %s" % str(terms))
	var inc: Dictionary = {}
	var inc_all: float = ai._incoming_total_on(sim, sim.units[ri], sim.units[ri].cell, inc)
	print("RCC|账|①/⑤ 的输入 `_incoming_total_on`（**对手主动打她**）= %.1f ｜明细=%s" % [
		inc_all, str(inc.get("pos", []))])
	var tr: float = ai._redcap_trade_gain(sim, sim.units[ri])
	print("RCC|账|④ 蓄爆 `_redcap_trade_gain`（**含复仇者 ×2**）= %.2f ｜ 她血=%d" % [
		tr, int(sim.units[ri].hp)])
	var ok := (lost_real == sim_hp0 - int(sim.units[ri].hp))
	print("RCC|判定|%s（真实掉血=%d ｜ 模拟掉血=%d ⇒ %s）" % [
		("PASS" if ok else "FAIL"), lost_real, sim_hp0 - int(sim.units[ri].hp),
		("两侧一致：模拟**确实**按 ×2 算了复仇者的反击" if ok else "**两侧不一致**：模拟没按 ×2 算")])
	print("RCC|END")
	get_tree().quit(0)

func _spawn(hid: String, fn, cell: Vector2i) -> Unit:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
	return u
