extends Node
## 【2026-10-01·一次性探针·只读】"AI 打爆玩家红帽"那一刀的**逐单位账**：
##   把 `②身价`（每一份值多少 = 身价 / 对面 ×1.25）与 `③血量账`（每一份掉多少血 × HP_VALUE_W × 池倍率）
##   逐单位打出来，看**自爆打死我方那个单位**到底有没有被记进账里、记了多少。
##
## 盘面同 `红帽自爆代价自检`：玩家红帽 2 血 @(3,4)｜AI 影丸 2 血（贴身）· 独脚龟 33 血（贴身）· 塔盾 40 血（远）。
##
## 输出：RB2|CFG / RB2|单位 / RB2|项 / RB2|合计 / RB2|判定 / RB2|END

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
	battle.units.clear(); battle.occupancy.clear(); battle.graves.clear(); battle.obstacles.clear(); battle.bombs.clear()
	GameState.no_death_limit = false
	GameState.match_over = false
	GameState.active_side = GameState.SIDE_ENEMY
	battle.state = battle.State.ENEMY_TURN
	for i in 2:
		await get_tree().process_frame
	_spawn("hero_40", DataRegistry.Faction.PLAYER, Vector2i(3, 4), 2)
	_spawn("hero_07", DataRegistry.Faction.ENEMY, Vector2i(3, 5), 2)
	_spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(3, 3), 33)
	_spawn("hero_11", DataRegistry.Faction.ENEMY, Vector2i(0, 1), 40)
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var ai = battle._make_battle_ai()
	ai.difficulty = GameState.ai_difficulty
	var snap := BattleSnapshot.collect(battle)
	var s1 = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var s2 = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var hi := -1
	var atk_i := -1
	# 【2026-10-01】攻方那一刀必须**真的打死她**才谈得上自爆 ⇒ 手工把攻方的有效攻击抬到 12
	#   （影丸近战 2 攻打 2 血的红帽只会掉 1 —— 被贴身压 1；前两版探针因此读到"没触发自爆"的假象）。
	for i in s1.units.size():
		var uu = s1.units[i]
		if uu != null and String(uu.hero_id) == "hero_07":
			uu.eatk = 12
			uu.atk = 12
	for i in s1.units.size():
		var u = s1.units[i]
		if u == null:
			continue
		if String(u.hero_id) == "hero_40":
			hi = i
		if String(u.hero_id) == "hero_07":
			atk_i = i
	ai.w_redcap_blast_self = 1.0     # 打开 ⑥ 做对照（生产默认 0 = 关）
	print("RB2|CFG|红帽 idx=%d ｜ 攻方影丸 idx=%d（eatk 抬到 12）｜ 打之前分=%.2f（⑥ 权重=1.0）" % [hi, atk_i, ai._evaluate(s1, true)])
	_dump_units(s1, "打之前")
	# ⚠️ 打的那一刀作用在 **s2** 上 ⇒ 攻方的抬攻也得在 s2 上来一次（前两版只改了 s1 ⇒ 打不死她）
	for i2 in s2.units.size():
		var u2 = s2.units[i2]
		if u2 != null and String(u2.hero_id) == "hero_07":
			u2.eatk = 12
			u2.atk = 12
	ai._apply(s2, atk_i, { "move": null, "atk": hi })
	print("RB2|打之后分=%.2f（Δ%+.2f）" % [ai._evaluate(s2, true), ai._evaluate(s2, true) - ai._evaluate(s1, true)])
	_dump_units(s2, "打之后")
	# ---- 拆 ②③ 两笔 ----
	var v_before := 0.0
	var v_after := 0.0
	var hp_pen_before := 0.0
	var hp_pen_after := 0.0
	for i in s1.units.size():
		var a = s1.units[i]
		var b = s2.units[i]
		if a != null and a.hp0 > 0:
			var va: float = ai._unit_value(s1, a)
			if int(a.fn) == int(DataRegistry.Faction.ENEMY):
				v_before += va
			else:
				v_before -= va * ai.PLAYER_VALUE_MULT
		if b != null and b.hp0 > 0:
			var vb: float = ai._unit_value(s2, b)
			if int(b.fn) == int(DataRegistry.Faction.ENEMY):
				v_after += vb
			else:
				v_after -= vb * ai.PLAYER_VALUE_MULT
		if a != null and a.hp0 > 0:
			var lost := maxf(float(a.hp0) - float(maxi(a.hp, 0)), 0.0)
			if lost > 0.0:
				if int(a.fn) == int(DataRegistry.Faction.ENEMY):
					hp_pen_before -= ai.w_hp_value * lost * ai._incoming_pool_mult(a)
				else:
					hp_pen_before += ai.w_hp_value * lost
		if b != null and b.hp0 > 0:
			var lost2 := maxf(float(b.hp0) - float(maxi(b.hp, 0)), 0.0)
			if lost2 > 0.0:
				if int(b.fn) == int(DataRegistry.Faction.ENEMY):
					hp_pen_after -= ai.w_hp_value * lost2 * ai._incoming_pool_mult(b)
				else:
					hp_pen_after += ai.w_hp_value * lost2
	print("RB2|项|②身价 %.2f → %.2f（Δ%+.2f）｜③血量账 %.2f → %.2f（Δ%+.2f）｜③ 里我方掉的那部分 = %.2f" % [
		v_before, v_after, v_after - v_before, hp_pen_before, hp_pen_after, hp_pen_after - hp_pen_before,
		hp_pen_after - hp_pen_before])
	# ---- 影丸的身价 = 多少分 ----
	for i in s1.units.size():
		var u = s1.units[i]
		if u == null:
			continue
		var val: float = ai._unit_value(s1, u)
		var pts: float = (val if int(u.fn) == int(DataRegistry.Faction.ENEMY) else val * ai.PLAYER_VALUE_MULT)
		print("RB2|单位|%s %s｜血 %d/%d｜身价 %.2f ⇒ **这一份在账上值 %.2f 分**｜池倍率 %.2f" % [
			String(u.hero_id), ("我方" if int(u.fn) == int(DataRegistry.Faction.ENEMY) else "对面"),
			int(u.hp), int(u.hp0), val, pts, ai._incoming_pool_mult(u)])
	# ---- 【判定实验】同一盘面，只把"我方影丸"手动打死 ⇒ 看 ②身价 动不动 ----
	var s3 = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var sc_before: float = ai._evaluate(s3, true)
	var bd_b: Dictionary = ai._eval_breakdown(s3)
	s3.units[1].alive = false            # 影丸（idx=1）
	var sc_after: float = ai._evaluate(s3, true)
	var bd_a: Dictionary = ai._eval_breakdown(s3)
	print("RB2|判定实验|把我方影丸直接打死：分 %.2f → %.2f（Δ%+.2f）" % [sc_before, sc_after, sc_after - sc_before])
	# ---- 【第二判定实验】走 **`_sim_take_damage`**（与自爆同一条路）把影丸打死 ⇒ 看 ②身价 动不动 ----
	var s4 = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	var bd4b: Dictionary = ai._eval_breakdown(s4)
	var v4b: float = ai._evaluate(s4, true)
	ai._sim_take_damage(s4, s4.units[1], 13, false, false, false)
	var bd4a: Dictionary = ai._eval_breakdown(s4)
	var v4a: float = ai._evaluate(s4, true)
	print("RB2|判定实验2|用 `_sim_take_damage(影丸, 13)` 打死它：影丸 alive=%s hp=%d ｜ 分 %.2f → %.2f（Δ%+.2f）" % [
		str(bool(s4.units[1].alive)), int(s4.units[1].hp), v4b, v4a, v4a - v4b])
	for k in bd4b.keys():
		var d2 := float(bd4a.get(k, 0.0)) - float(bd4b[k])
		if absf(d2) >= 0.05:
			print("RB2|判定实验2|%s：%.2f → %.2f（Δ%+.2f）" % [String(k), float(bd4b[k]), float(bd4a.get(k, 0.0)), d2])
	for k in bd_b.keys():
		var d := float(bd_a.get(k, 0.0)) - float(bd_b[k])
		if absf(d) >= 0.05:
			print("RB2|判定实验|%s：%.2f → %.2f（Δ%+.2f）" % [String(k), float(bd_b[k]), float(bd_a.get(k, 0.0)), d])
	print("RB2|END")
	get_tree().quit(0)

func _dump_units(s, tag: String) -> void:
	var out: Array = []
	for i in s.units.size():
		var u = s.units[i]
		if u == null:
			continue
		out.append("%s%s hp%d/%d alive=%s" % [
			("我" if int(u.fn) == int(DataRegistry.Faction.ENEMY) else "敌"),
			String(u.hero_id).substr(5), int(u.hp), int(u.hp0), str(bool(u.alive))])
	print("RB2|%s|%s" % [tag, " ｜ ".join(out)])

func _spawn(hid: String, fn, cell: Vector2i, hp: int) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.moved_this_turn = false
		u.attacked_this_turn = false
		u.hp = hp
