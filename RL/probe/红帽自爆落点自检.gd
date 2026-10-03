extends Node
## 【2026-10-03 一次性探针·只读】对手红帽 hero_40 的扑街自爆 —— **落点圈**到底有多大。
##   老口径（T?? 之前）= "她**此刻**就贴着本格"（`grid.distance(她, 本格) == 1`）⇒ 只为"她原地倒下"买单；
##   新口径（2026-10-03·用户拍板「a」）= "**她下回合走得到、并在那儿倒下**"
##     ⇒ 判据 = `1 ≤ walk_dist(她 → 本格) ≤ 她下回合移动力 + 1`（她走到本格**旁边**再死就够）。
## 盘面（合成盘 5×7 · 只为读数）：
##   · 敌方阵营 hero_49（我方试验单位，属性人造：hp 30 / atk 4 / 射程 1 / 移动 2）放在她 **walk_dist = 3** 处
##     ⇒ 保证 `_redcap_blast_threat()`（她的血 ≤ 我方最大单击）能按需开门；
##   · 玩家阵营 hero_40 红帽在 (2,3)，max_hp 12（血量按臂设置）。
## 臂：A 她满血 12（门关）· B 她 1 血（门开·新口径）· C 她 1 血但被[沉默] · D 她 1 血但移动力 0（钉住）。
## 每一臂逐格打印：老口径收不收 / 新口径收不收 / 收多少（`_aoe_riders_on()` 的原始值）。
const AI_SRC := preload("res://src/BattleAI.gd")
const WEIGHTS := "res://RL/weights/噩梦1.json"

var _grid: HexGrid
var _nm: Dictionary = {}

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("PROBE|WATCHDOG|120s"); get_tree().quit(2))
	_run.call_deferred()

func _run() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_nm = _load_json(WEIGHTS)
	var ai = AI_SRC.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.set_weights(_nm)

	var her_cell: Vector2i = Vector2i(2, 3)
	# ① 先用一张"探路盘"量出各格到她（她占着 (2,3)，其余空）的路网距离
	var probe_descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", Vector2i(0, 0), "探路"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var sim0 = ai.build_state(probe_descs, { Vector2i(0, 0): 0, her_cell: 1 }, {}, {}, {}, {}, {})
	var me_cell: Vector2i = Vector2i(0, 0)
	var by_d: Dictionary = {}
	for c in _grid.all_cells():
		if c == her_cell:
			continue
		var d: int = ai.walk_dist(sim0, her_cell, c)
		if d <= 0 or d > 6:
			continue
		if not by_d.has(d):
			by_d[d] = c
		if d == 3 and me_cell == Vector2i(0, 0):
			me_cell = c
	print("PROBE|格子取样（到她 walk_dist ⇒ 代表格）：%s" % _d_txt(by_d))
	print("PROBE|我方试验单位摆在她 walk_dist=3 的 %s" % str(me_cell))

	# ② 正式盘：我方试验单位 + 她
	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", me_cell, "我方试验单位"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var occ: Dictionary = { me_cell: 0, her_cell: 1 }
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var me = sim.units[0]
	var her = sim.units[1]
	# 人造属性：只为让两把尺子（她能不能被一击杀 / 自爆 13 点够不够扣）读起来干净
	me.hp = 30; me.max_hp = 30
	me.atk = 4; me.eatk = 4
	me.atk_range = 1; me.atk_type = DataRegistry.AttackType.MELEE
	me.move = 2; me.emove = 2
	her.max_hp = 12
	print("PROBE|我方 hp=%d atk=%d 射程=%d 移动=%d · 她 max_hp=%d 移动=%d（walk_dist 她→我方=%d）" % [
		me.hp, me.atk, me.atk_range, me.emove, her.max_hp, her.emove,
		ai.walk_dist(sim, her_cell, me_cell)])

	var kline: float = ai._redcap_kill_line(sim, her)
	print("PROBE|安全血线（我方对她的最大单击）= **%.2f** ⇒ 危险线（× %.1f，T146 新口径）= **%.2f**" % [
		kline, AI_SRC.REDCAP_NEAR_LINE_MULT, kline * AI_SRC.REDCAP_NEAR_LINE_MULT])
	var arms: Array = [
		["A 她满血 12（> 危险线 ⇒ 门应关）", 12, false, 2],
		["B 她 1 血（≤ 一击线 ⇒ 门开）", 1, false, 2],
		["C 她 1 血 + 被沉默", 1, true, 2],
		["D 她 1 血 + 移动力 0（钉住）", 1, false, 0],
		["E 她 9 血（= 危险线 + 1 ⇒ 门应关）", 9, false, 2],
		["F 她 8 血（= 危险线 ⇒ 门应开·T146 新口径）", 8, false, 2],
	]
	for arm in arms:
		her.hp = int(arm[1])
		her.silenced = bool(arm[2])
		her.emove = int(arm[3])
		var open: bool = ai._redcap_blast_threat(sim, her)
		var budget: int = ai._threat_emove_next(sim, her)
		print("PROBE|===== %s =====" % arm[0])
		print("PROBE|  门 `_redcap_blast_threat()` = %s · 她下回合移动力 = %d ⇒ 新口径应收 d ≤ %d" % [
			"开" if open else "关", budget, budget + 1])
		var line := ""
		for d in [1, 2, 3, 4, 5]:
			if not by_d.has(d):
				continue
			var cell: Vector2i = by_d[d]
			var old_ok: bool = _grid.distance(her_cell, cell) == 1
			var rd: Array = ai._aoe_riders_on(sim, me, cell)
			var v := 0.0
			for r in rd:
				v = maxf(v, float(r[1]))
			# 这一笔最终喂给 AI 的那把尺子（①.8 ⇒ 挨打合计 / ㉛）
			var inc: float = ai._incoming_total_on(sim, me, cell)
			line += "d=%d 老=%s 新=%s(%.2f) 挨打合计=%.2f  |  " % [d, "收" if old_ok else "—", "收" if v > 0.0 else "—", v, inc]
		print("PROBE|  %s" % line)
		# 这一笔在**真正读它的两个项**里各是多少：㉛（只用 ㉖ 门外的单位）· 阶段 1 的 AoE 团队总账（全队）
		var d_me: int = ai.walk_dist(sim, her_cell, me_cell)
		print("PROBE|  本单位实际站在 %s（她→它 walk_dist=%d·㉖ 门内? %s）⇒ ㉛ 项 = %.2f · 阶段1 AoE 总账 = %.2f" % [
			str(me.cell), d_me, "在" if ai._exposure_covered(me) else "不在",
			ai._aoe_rider_total(sim), ai._open_aoe_total(sim)])
		# 圈内格数（她下回合走得到 + 邻格）——量"AI 要躲多大一片"
		var z := 0
		var alln := 0
		for c2 in _grid.all_cells():
			var dd: int = ai.walk_dist(sim, her_cell, c2)
			if dd <= 0:
				continue
			alln += 1
			if new_ok(her_cell, c2, dd, budget):
				z += 1
		print("PROBE|  落点圈 = 盘上 %d 格里的 %d 格（老口径只有 %d 格）" % [
			alln, z, _grid.neighbors(her_cell).size()])
	print("PROBE|END")
	get_tree().quit(0)

## 新口径的纯几何版（只看路网距离，与 `_redcap_blast_zone()` 同一句判据）
func new_ok(her_cell: Vector2i, cell: Vector2i, d: int, budget: int) -> bool:
	if _grid.distance(her_cell, cell) == 1:
		return true
	return d >= 1 and d <= budget + 1

func _d_txt(by_d: Dictionary) -> String:
	var ks: Array = by_d.keys()
	ks.sort()
	var s := ""
	for k in ks:
		s += "d=%d→%s  " % [int(k), str(by_d[k])]
	return s

func _desc(fn: int, hid: String, cell: Vector2i, nm: String) -> Dictionary:
	var hd = DataRegistry.heroes[hid]
	var emove := 2
	if (hd.skills as Array).has(DataRegistry.Skill.SWIFT):
		emove = 3
	return {
		"fn": fn, "hero": hid, "cell": cell, "hp": int(hd.max_hp), "max_hp": int(hd.max_hp),
		"atk": int(hd.atk), "eatk": int(hd.atk), "move": emove, "emove": emove,
		"atk_range": maxi(int(hd.attack_range), 1), "atk_type": int(hd.attack_type),
		"skills": (hd.skills as Array).duplicate(), "name": nm,
	}

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}
