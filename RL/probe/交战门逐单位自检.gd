extends Node
## 【2026-09-26 一次性探针·临时】⑥规则B 的**逐单位门**自检 —— 用户原话：
##   「我怀疑我知道为什么了，因为开局的时候，就能摸到 AI，所以开局就是交战状态」。
## 旧口径 `Sim.engaged0` = **全队一个布尔**（我方任一单位落在敌方任一单位「射程＋移动力」圈内 ⇒
##   **全体**免罚）⇒ 5×7 的盘、威胁圈常见 4~6 格 ⇒ 从第 1~2 回合起基本恒关、⑥ 整项形同不存在。
## 用户随后否掉"谁在圈里谁免罚"（原话：「如果只有一个单位在威胁圈，那他就会自己去送死」）⇒
## 新口径 = **这个单位本回合够不够得到任何敌人**（`SimUnit.reach0`：路网距离 ≤ `emove + atk_range`，
##   与 ⑤位置拉力 同一把尺子；**本回合行动前**快照、整回合不变；够得到 ⇒ 免罚）。
##
## 两块盘面（都只读，不改生产）：
##   A 混合：长剑离玩家 2 格（**能还手**）· 雪拳在角落（**够不到人**，而它那一带是会被集火的）
##     ⇒ 旧门显示"已交战"（旧口径**全体**免罚），新口径只罚够不到的那个。
##   B 全队都能还手 ⇒ 新旧口径同为 0（证明门不是被一律关掉）。
## 每块盘面打印：旧门 `engaged0` · 每个我方单位的 `reach0 / near / gate / 阈值 / 当前挨打 / ⑤拉力 / 它自己的⑥罚`，
##   再把"走到候选里最挨打的那一格"之后的 ⑥ 三档并列（**新 / 旧口径复刻 / 关**）。
##
## 输出：每行 `GTU|...`，末尾 `GTU|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	# ⚠️ 用**不带顶部缺口**的 7×5 盘（`top_cap_cols` 那两个格子会让 `los_blocked` 把顶行的射击线判死，
	#   第一版就因此读出一片 0 —— 见本探针 §第 2 次运行）
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	var w := _load_flat_weights(NIGHTMARE_PATH)
	var ai = _mk_ai(w)
	var thr := float(w.get("MOVE_ACCEPT_DAMAGE", 0.0))
	var hpw := float(w.get("HP_VALUE_W", 1.0))
	var pull := float(w.get("ENGAGE_PULL_PER_CELL", 1.2))
	print("GTU|CFG|fork=%s|w=%s|阈值=%.0f|HP_VALUE_W=%.2f|ENGAGE_PULL_PER_CELL=%.2f" % [
		_sha("res://RL/ai/AI_Battle.gd"), _sha(NIGHTMARE_PATH), thr, hpw, pull])

	var da := _board_a()
	var sa = ai.build_state(da, _occ(da), {}, {}, {}, {}, {})
	# 假通过守卫：fork 里还没有逐单位门（`reach0`）时直接判失败 —— 否则新旧读数一样会被误读成"改了没影响"
	var any_ai = _first_ai(sa)
	if any_ai == null or any_ai.get("reach0") == null:
		print("GTU|GUARD|FAIL|fork 里没有 SimUnit.reach0 ⇒ 逐单位门没同步进 fork（重建后重跑）")
		get_tree().quit(1)
		return
	_panel(ai, "A混合", da, sa, thr, hpw, pull)
	var db := _board_b()
	var sb = ai.build_state(db, _occ(db), {}, {}, {}, {}, {})
	_panel(ai, "B全队能还手", db, sb, thr, hpw, pull)
	print("GTU|END")
	get_tree().quit(0)

func _panel(ai, tag: String, descs: Array, sim, thr: float, hpw: float, pull: float) -> void:
	print("GTU|%s|⑥对比|旧口径复刻(全队一个门)=%.2f|新口径(逐单位)=%.2f|旧门 engaged0=%s ⇒ 旧口径%s" % [
		tag, _old_six(ai, sim, thr, hpw), float(ai._rule_b_score(sim)), str(bool(sim.engaged0)),
		"全体免罚" if bool(sim.engaged0) else "全队受约束"])
	# 【诊断·只跑一次】甲 → 雪拳 那一笔为什么是 0（挨打合计 = 0 时逐段打出来）
	var tgt = _first_ai(sim)
	if tgt != null:
		for v1 in sim.units:
			if v1 == null or not v1.alive or v1.fn == tgt.fn:
				continue
			var dd := int(ai.walk_dist(sim, v1.cell, tgt.cell))
			var ok1: bool = bool(ai._threat_can_hit(sim, v1, tgt.cell, tgt))
			var hv := float(ai._threat_hit_value(sim, v1, dd, false, tgt.cell, tgt))
			var am := float(ai._hit_after_target_mods(sim, tgt, tgt.cell, hv))
			print("GTU|%s|诊断|%s→%s|walk_dist=%d|_threat_can_hit(带目标)=%s|单击=%.1f|倍率=%.2f|受击修正后=%.1f|开火位=%d|它自己eatk=%.0f|它的技能=%s" % [
				tag, str(v1.name), str(tgt.name), dd, str(ok1), hv,
				float(ai._sim_mult_at(sim, v1, tgt, tgt.cell)), am,
				int(ai._threat_slots(sim, tgt, tgt.cell)), float(v1.eatk), str(v1.skills)])
	# 【诊断】sim 里每个单位的**实际**数值（descs 里写的值与英雄定义/fixup 之后的真值可能不同）
	for u0 in sim.units:
		if u0 == null or not u0.alive:
			continue
		print("GTU|%s|盘面|%s|fn=%d|%s|hp=%d|eatk=%.0f|emove=%d|range=%d|type=%d" % [tag, str(u0.name),
			int(u0.fn), str(u0.cell), int(u0.hp), float(u0.eatk), int(u0.emove), int(u0.atk_range),
			int(u0.atk_type)])
	# 【诊断】对手能不能打到这个单位的格：逐个对手打 `_threat_can_hit` + 路网距离
	for u0 in sim.units:
		if u0 == null or not u0.alive or u0.fn != DataRegistry.Faction.ENEMY:
			continue
		var bits: Array[String] = []
		for v0 in sim.units:
			if v0 == null or not v0.alive or v0.fn == u0.fn:
				continue
			bits.append("%s@%s %s" % [str(v0.name), str(v0.cell),
				("够得到" if bool(ai._threat_can_hit(sim, v0, u0.cell)) else "够不到")])
		print("GTU|%s|谁能打到 %s：%s" % [tag, str(u0.name), "；".join(bits)])
	for i in sim.units.size():
		var u = sim.units[i]
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var near := int(ai._nearest_enemy_dist(sim, u))
		var gate := int(u.emove) + int(u.atk_range)
		var inc_cur := float(ai._incoming_total_on(sim, u, u.cell))
		var thr_u := float(ai._accept_threshold(u))
		var own := 0.0
		if thr_u > 0.0 and inc_cur > thr_u:
			own = (inc_cur - thr_u) * hpw
		var pull_v := 0.0
		if near > gate:
			pull_v = -float(near - gate) * pull
		print("GTU|%s|%s|%s|reach0=%s|near=%d|gate=%d|阈值=%.0f|挨打当前=%.0f|⑤拉力=%.2f|它自己⑥罚=%.2f" % [
			tag, str(u.name), str(u.cell), str(bool(u.reach0)), near, gate, thr_u, inc_cur, pull_v, own])
		# 候选落点里"最挨打"的那一格（纯走位那一手）⇒ 走上去之后 ⑥ 三档并列
		var inc_max := inc_cur
		var cell_max: Vector2i = u.cell
		var combo_max: Dictionary = {}
		for combo in ai._actions_for(sim, i):
			var mc: Vector2i = u.cell
			if combo.get("move") != null:
				mc = combo["move"]
			var v := float(ai._incoming_total_on(sim, u, mc))
			if v > inc_max:
				inc_max = v
				cell_max = mc
				combo_max = combo
		if combo_max.is_empty():
			print("GTU|%s|%s|没有更挨打的落点（候选里最大就是当前格 %.0f）" % [tag, str(u.name), inc_max])
			continue
		var c = sim.clone()
		ai._apply(c, i, combo_max)
		print("GTU|%s|%s|走到最挨打的 %s：挨打 %.0f ⇒ ⑥新=%.2f ⑥旧口径复刻=%.2f ⑥关=0.00" % [
			tag, str(u.name), str(cell_max), inc_max, float(ai._rule_b_score(c)),
			_old_six(ai, c, thr, hpw)])

## 旧口径复刻（只为本探针对照）：**全队一个门** —— `engaged0` 为真 ⇒ 全体 0；否则全体按阈值罚。
func _old_six(ai, sim, thr: float, hpw: float) -> float:
	if bool(sim.engaged0):
		return 0.0
	var s := 0.0
	for u in sim.units:
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		var inc := float(ai._incoming_total_on(sim, u, u.cell))
		s += maxf(inc - thr, 0.0) * hpw
	return s

func _first_ai(sim):
	for u in sim.units:
		if u != null and u.alive and u.fn == DataRegistry.Faction.ENEMY:
			return u
	return null

func _occ(descs: Array) -> Dictionary:
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i     # ⚠️ 值必须是**单位下标**（不是 true）—— 传 true 会让 sim.occ 空掉
	return occ

## A：长剑(4,1) 离玩家甲(6,1) 两格 ⇒ 能还手；雪拳(0,2) 在另一头 ⇒ 够不到人（near 5+），
##   而它那一带被三个远程的「移动3＋射程3=6」罩着 ⇒ 不往前走也要挨打。旧门因长剑已进圈而**全队关闭**。
func _board_a() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	return [
		_u(E, "hero_26", Vector2i(0, 2), 26, 26, 5, 3, 1, MELEE, [], "雪拳"),
		_u(E, "hero_18", Vector2i(4, 1), 20, 20, 6, 3, 1, MELEE, [], "长剑"),
		_u(P, "hero_37", Vector2i(6, 1), 20, 20, 5, 3, 3, RANGED, [], "玩家远程甲"),
		_u(P, "hero_23", Vector2i(6, 3), 20, 20, 5, 3, 3, RANGED, [], "玩家远程乙"),
		_u(P, "hero_11", Vector2i(5, 4), 20, 20, 4, 3, 3, RANGED, [], "玩家远程丙"),
	]

## B：两个我方单位都贴着玩家（near=1 ≤ gate）⇒ 新口径也免罚（对照组）
func _board_b() -> Array:
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var RANGED := int(DataRegistry.AttackType.RANGED)
	return [
		_u(E, "hero_18", Vector2i(3, 1), 20, 20, 6, 3, 1, MELEE, [], "长剑"),
		_u(E, "hero_26", Vector2i(3, 2), 26, 26, 5, 3, 1, MELEE, [], "雪拳"),
		_u(P, "hero_37", Vector2i(4, 1), 20, 20, 5, 3, 3, RANGED, [], "玩家远程甲"),
		_u(P, "hero_23", Vector2i(2, 2), 20, 20, 5, 3, 3, RANGED, [], "玩家远程乙"),
	]

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 2
	ai.log_decisions = false
	ai.time_budget_ms = 0
	ai.set_weights(inject)
	return ai

func _load_flat_weights(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = {}
	for k in (d as Dictionary).keys():
		if String(k).begins_with("_"):
			continue
		out[String(k)] = (d as Dictionary)[k]
	return out

func _sha(path: String) -> String:
	return _sha12(path)

func _sha12(path: String) -> String:
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
