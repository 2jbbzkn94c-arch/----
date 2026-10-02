extends Node
## 【2026-10-01·用户「她没考虑 AI 已经死了 2 个了啊，**自爆就输了**」】**终局项要按"累计阵亡"算**。
##
## 老口径（`_terminal_value()` 按**场上存活数**）：3 人 → 2 人 = `MINE_CURVE[2] = −10` × `TERMINAL_W 0.25`
##   = **−2.5 分** —— 队伍是 4/5 人时，"第 3 个阵亡 = 判负"这件事在评分里几乎看不见（用户那局
##   AI 已阵亡 2、场上还剩 3 ⇒ 红帽自爆 = 第 3 死 = **直接输**，它却只看到 −2.5）。
## 新口径（按"还剩几条命" = `判负线 − 累计阵亡`）：同样那一死 = `MINE_CURVE[0] = −1000` × 0.25
##   = **−250 分**。
##
## 本探针直接量两边：同一盘面各建两份模拟盘（"打死我方一个非红帽单位"之前 / 之后），比较
##   `⑩终局项` 的变化量。**臂 A** = 不带 `deads`（老口径）｜**臂 B** = `deads.my = 2`（我方已阵亡 2 名）。
## 期望：B 的下降 ≥ 20 × A 的下降。
##
## 输出：RCB2|CFG / RCB2|臂 / RCB2|判定 / RCB2|END

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
	battle.buff_items.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	# 我方场上 3 人（观感就是"3 人队"）+ 玩家 2 人
	_spawn("hero_40", DataRegistry.Faction.ENEMY, Vector2i(1, 1), 13)
	_spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(0, 1), 33)
	_spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(2, 1), 40)
	_spawn("hero_04", DataRegistry.Faction.PLAYER, Vector2i(1, 4), 18)
	_spawn("hero_12", DataRegistry.Faction.PLAYER, Vector2i(2, 4), 24)
	for i in 3:
		await get_tree().process_frame
	print("RCB2|CFG|我方场上 %d 人 ｜ 玩家 %d 人 ｜ 判负线 %d" % [
		_alive(DataRegistry.Faction.ENEMY), _alive(DataRegistry.Faction.PLAYER), battle.LOSS_DEATH_COUNT])
	var a := await _arm(false)     # 老口径（不带 deads）
	var b := await _arm(true)      # 累计阵亡已知（我方已死 2）
	var drop_a: float = float(a[0]) - float(a[1])
	var drop_b: float = float(b[0]) - float(b[1])
	print("RCB2|判定|臂 A（老口径·按存活数）：%.1f → %.1f（Δ%+.1f）｜臂 B（按累计阵亡·已死 2）：%.1f → %.1f（Δ%+.1f）" % [
		float(a[0]), float(a[1]), -drop_a, float(b[0]), float(b[1]), -drop_b])
	var ok: bool = drop_b >= drop_a * 20.0 and drop_b > 0.0
	print("RCB2|判定|%s（B 的跌幅是 A 的 %.0f 倍 ⇒ 「第 3 死 = 判负」现在压得住）" % [
		("PASS" if ok else "FAIL"), (drop_b / maxf(drop_a, 0.001))])
	print("RCB2|END")
	get_tree().quit(0)

## 一份臂：建两份同样的模拟盘（带/不带 deads），把**我方一个非红帽单位**打死，返回
## `[打死前 ⑩终局项, 打死前+打死后的 ⑩终局项]`。
func _arm(with_deads: bool) -> Array:
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle)
	var deads := ({ "my": 2, "foe": 0, "line": battle.LOSS_DEATH_COUNT } if with_deads else {})
	var s0 = _mk(ai, snap, deads)
	var s1 = _mk(ai, snap, deads)
	# 打死我方第一个**非红帽**单位（避免红帽自爆那套副作用干扰读数）
	var target = null
	for u in s1.units:
		if u != null and bool(u.alive) and int(u.fn) == int(DataRegistry.Faction.ENEMY) \
				and String(u.hero_id) != "hero_40":
			target = u
			break
	if target != null:
		target.alive = false
		ai._sim_on_died(s1, target)
	var v0 := float((ai._eval_breakdown(s0) as Dictionary).get("⑩终局项", 0.0))
	var v1 := float((ai._eval_breakdown(s1) as Dictionary).get("⑩终局项", 0.0))
	print("RCB2|臂|带 deads=%s ⇒ ⑩终局项 %.1f → %.1f（Δ%+.1f）" % [str(with_deads), v0, v1, v1 - v0])
	return [v0, v1]

func _mk(ai, snap: Dictionary, deads: Dictionary):
	return ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {},
			snap.get("buff_owner", {}), deads)

func _alive(fn: int) -> int:
	var n := 0
	for u in battle.units:
		if u != null and is_instance_valid(u) and u.alive and u.faction == fn:
			n += 1
	return n

func _spawn(hid: String, faction: int, cell: Vector2i, hp: int) -> void:
	var u := battle._spawn_unit(hid, faction, cell)
	if u != null:
		u.hp = hp
