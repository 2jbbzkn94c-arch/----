extends Node
## 【2026-10-02·一次性探针·只读】两件事一起验（T138 ＋ T139）：
##   **A/B 臂（T138·共鸣者）**：同一块盘面、"队友攻击力之和 = 8"、对面一个 **8 血** 目标 ⇒
##     · A **回合开始的先补位**（`_start_placing_subs = true`）⇒ 共鸣会结算 ⇒ `sub_kill_scan` 应当**看得见这一刀**；
##     · B **回合中途落位**（同前，但 false）⇒ echo 不结算（0 攻）⇒ 应当**看不见**（T70 定的口径，逐位不变）。
##   **C 臂（T139·嘲讽护住）**：给那个 8 血目标贴一个带 `<嘲讽>` 的 梅林 ⇒ 任何"能打到目标"的开火格
##     多半也够得到梅林 ⇒ 真规则下这一刀必须打梅林 ⇒ `sub_kill_scan` **不该**再报"能一刀收"；
##     同时把**旧尺**（`_adj_foe_hit_on`，d 硬编码 1）与**新尺**（`_sub_reach_hit`，真开火格＋嘲讽门）并排打出来。
## 输出：RC|… / RC|END

const ECHO := "hero_47"

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	GameState.ai_difficulty = 2
	await _rebuild()
	GameState.ai_difficulty = 2
	await _arm("A/B 臂", false)
	await _rebuild()
	await _arm("C 臂", true)
	print("RC|END")
	get_tree().quit(0)

func _arm(tag: String, taunt_guard: bool) -> void:
	# 我方在场队友：影丸(攻 5) ＋ 嬉皮死神(攻 3) ⇒ 和为 8
	_spawn("hero_07", DataRegistry.Faction.ENEMY, Vector2i(1, 1), 14)
	_spawn("hero_30", DataRegistry.Faction.ENEMY, Vector2i(0, 1), 20)
	# 玩家：8 血红帽（= 那一刀的目标）
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(3, 3), 8)
	if taunt_guard:
		_spawn("hero_36", DataRegistry.Faction.PLAYER, Vector2i(3, 2), 20)   # 梅林（带 <嘲讽>）
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	battle._refresh_board()
	var atk_sum := 0
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == DataRegistry.Faction.ENEMY:
			atk_sum += int(u.effective_atk())
	print("RC|%s·盘面|我方在场攻击力和 = **%d**｜目标 = 红帽 8 血%s" % [
		tag, atk_sum, ("｜**目标旁边贴着带[嘲讽]的梅林**" if taunt_guard else "")])
	for flag in [true, false]:
		battle._start_placing_subs = flag
		var cells: Array = battle._sub_legal_cells_for_ai()
		var cands: Array = [ECHO]
		var ai = battle._make_battle_ai()
		ai.difficulty = GameState.ai_difficulty
		battle._wire_echo_for(ai)          # ← 生产同款：按"这一手会不会结算共鸣"喂
		var scan: Dictionary = battle._sub_kill_scan(cands, cells)
		var probe = ai._sub_probe_unit(ECHO, Vector2i(-99, -99))
		var head := ("**回合开始的先补位**（echo 会结算）" if flag else "**回合中途落位**（echo 不结算）")
		print("RC|%s·%s|探针 eatk=%d echo_set=%d｜`sub_kill_scan` = %s" % [
			tag, head, int(probe.eatk), int(probe.echo_set),
			("**空**（判成没人能收）" if scan.is_empty() else "**能收**：%s 落 %s（需要 %.0f = 队友 %.0f ＋ 这一手 %.0f）" % [
				String(scan.get("hero", "?")), str(scan.get("cell", Vector2i(-99, -99))),
				float(scan.get("need", 0.0)), float(scan.get("team", 0.0)), float(scan.get("sub", 0.0))])])
		# 旧尺 vs 新尺（只在"回合开始"口径下比 —— 那才代表"承诺 vs 实战"）
		if flag:
			var snap := BattleSnapshot.collect(battle)
			var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
				snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
				snap.get("buff_owner", {}), snap.get("deads", {}))
			var tgt = null
			for u in sim.units:
				if u.hero_id == "hero_40":
					tgt = u
			var land: Vector2i = cells[0] if cells.size() > 0 else Vector2i(-99, -99)
			var sub_u = ai._sub_probe_unit(ECHO, land)
			sub_u.echo_set = ai.echo_sum_here if ai.echo_sum_here > 0 else -1
			sub_u.eatk = sub_u.echo_set if sub_u.echo_set > 0 else 0
			sim.units.append(sub_u)
			var old_v: float = float(ai._adj_foe_hit_on(sim, tgt, sub_u))
			var new_v: float = float(ai._sub_reach_hit(sim, sub_u, land, tgt))
			print("RC|%s·两把尺子|落点 %s ⇒ **旧尺**（`_adj_foe_hit_on`，d=1 硬编码）= %.1f｜**新尺**（`_sub_reach_hit`，真开火格＋嘲讽门＋真实单击）= %.1f｜目标血 %.0f ⇒ 旧尺%s、新尺%s" % [
				tag, str(land), old_v, new_v, float(tgt.hp),
				("**会报「能收」**" if old_v >= float(tgt.hp) else "不报"),
				("报能收" if new_v >= float(tgt.hp) else "**不报**")])
	battle._start_placing_subs = false

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
