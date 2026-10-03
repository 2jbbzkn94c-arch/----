extends Node
## 【2026-10-03 一次性探针·只读】"**不要把红帽打到安全血线以下**"（用户口径：AI 没有解决方案时别压她的血线；
##   玩家已经死两个了就可以打）—— 逐臂打 `_redcap_push_unsafe()` 的判据与候选表。
##   安全血线 = `_redcap_kill_line()`（我方对她能落上去的最大单击）；这一击把她从"打不死"压到"一碰就死" = 拦。
##   合成盘（5×7 · 只为读数）：
##     · 盘 A：我方 hero_49（人造 hp 30 / atk 4 / 射程 1 / 移动 2）**贴着她** + 我方第二人摆在"她的落点圈里"（d=2）
##     · 盘 C：我方 hero_49 改成**远程**（射程 4）站在 **d=4（圈外）**，全场只有它
##     · 玩家阵营 hero_40 红帽在 (2,3)，血量按臂设置（`max_hp` 12）
##   七臂：A 基准（应拦）· B 玩家已死 2（放行）· C 圈里没人（放行）· D 她被沉默（放行）·
##        E 她本来就在线下（放行）· F 压不到线下（放行）· G 这一击会打死她（本函数放行 → 点杀护栏接住）
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
	# ① 探路盘：量各格到她（她占 (2,3)、其余空）的路网距离，挑出 d=1 / d=2 / d=4 三个代表格
	var probe_descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", Vector2i(0, 0), "探路"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var sim0 = ai.build_state(probe_descs, { Vector2i(0, 0): 0, her_cell: 1 }, {}, {}, {}, {}, {})
	var c1: Vector2i = Vector2i(-9, -9)
	var c2: Vector2i = Vector2i(-9, -9)
	var c4: Vector2i = Vector2i(-9, -9)
	for c in _grid.all_cells():
		if c == her_cell or c == Vector2i(0, 0):
			continue
		var d: int = ai.walk_dist(sim0, her_cell, c)
		if d == 1 and c1.x < 0:
			c1 = c
		elif d == 2 and c2.x < 0:
			c2 = c
		elif d == 4 and c4.x < 0:
			c4 = c
	print("PROBE|代表格：贴身 d=1 → %s · 圈内 d=2 → %s · 圈外 d=4 → %s" % [str(c1), str(c2), str(c4)])

	# ② 盘 A：我方近战贴着她（下标 0）+ 我方第二人在圈内 d=2（下标 1）+ 她（下标 2）
	var descs: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", c1, "矿工甲"),
		_desc(DataRegistry.Faction.ENEMY, "hero_49", c2, "队友乙"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var simA = ai.build_state(descs, { c1: 0, c2: 1, her_cell: 2 }, {}, {}, {}, {}, {})
	var pokerA = simA.units[0]
	var mateA = simA.units[1]
	var herA = simA.units[2]
	for x in [pokerA, mateA]:
		x.hp = 30; x.max_hp = 30
		x.atk = 4; x.eatk = 4
		x.atk_range = 1; x.atk_type = DataRegistry.AttackType.MELEE
		x.move = 2; x.emove = 2
	herA.max_hp = 12
	herA.move = 2; herA.emove = 2

	# ③ 盘 C：我方**远程**（射程 4）站在圈外 d=4，全场只有它
	var descsC: Array = [
		_desc(DataRegistry.Faction.ENEMY, "hero_49", c4, "远程丙"),
		_desc(DataRegistry.Faction.PLAYER, "hero_40", her_cell, "红帽"),
	]
	var simC = ai.build_state(descsC, { c4: 0, her_cell: 1 }, {}, {}, {}, {}, {})
	var pokerC = simC.units[0]
	var herC = simC.units[1]
	pokerC.hp = 30; pokerC.max_hp = 30
	pokerC.atk = 4; pokerC.eatk = 4
	pokerC.atk_range = 4; pokerC.atk_type = DataRegistry.AttackType.RANGED
	pokerC.move = 2; pokerC.emove = 2
	herC.max_hp = 12; herC.move = 2; herC.emove = 2

	var lineA: float = ai._redcap_kill_line(simA, herA)
	var lineC: float = ai._redcap_kill_line(simC, herC)
	print("PROBE|安全血线：盘A（近战 4 攻贴身）= %.2f · 盘C（射程 4 站圈外）= %.2f" % [lineA, lineC])
	print("PROBE|盘A 我方在圈里：矿工甲 %s（d=1）· 队友乙 %s（d=2）⇒ 圈内有 %d 人" % [
		str(pokerA.cell), str(mateA.cell), _zone_count(ai, simA, herA)])

	# ④ 七臂
	var arms: Array = [
		["A 基准：她 %d 血·圈里有人·玩家 0 死 ⇒ 应**拦**", "A", int(lineA) + 1, 0, false],
		["B 玩家已死 2（再死一个就判负）⇒ 应**放行**", "A", int(lineA) + 1, 2, false],
		["C 圈里没人（远程在 d=4 点她）⇒ 应**放行**", "C", int(lineC) + 1, 0, false],
		["D 她被[沉默] ⇒ 应**放行**", "A", int(lineA) + 1, 0, true],
		["E 她本来就在线下 ⇒ 应**放行**（不是这一击压的）", "A", maxi(int(lineA) - 1, 1), 0, false],
		["F 这一击压不到线下 ⇒ 应**放行**", "A", int(lineA) + 8, 0, false],
		["G 这一击会**打死**她 ⇒ 本函数放行、点杀护栏接住", "A", 2, 0, false],
	]
	for arm in arms:
		var which := String(arm[1])
		var sim = simA if which == "A" else simC
		var poker = pokerA if which == "A" else pokerC
		var her = herA if which == "A" else herC
		var idx_her := 2 if which == "A" else 1
		her.hp = int(arm[2])
		her.silenced = bool(arm[4])
		sim.foe_dead = int(arm[3])
		var threat: bool = ai._redcap_blast_threat(sim, her)
		var push: bool = ai._redcap_push_unsafe(sim, poker, idx_her, poker.cell)
		var kill: bool = ai._redhood_kill_unsafe(sim, poker, idx_her, poker.cell)
		# 候选表里"打她"那几手还在不在（端到端读数）—— ⚠️ 取两次，顺便验 `_actions_for()` 是否幂等
		var a1: Array = ai._actions_for(sim, 0)
		var a2: Array = ai._actions_for(sim, 0)
		var n1 := _count(a1, idx_her)
		var n2 := _count(a2, idx_her)
		print("PROBE|===== %s =====" % arm[0])
		print("PROBE|  她 hp=%d · 安全血线=%.2f · 门 `_redcap_blast_threat()`=%s ⇒ 候选表里打她的 = **%d** 手（全部 %d 手；再取一次 %d/%d）· 压血线护栏=%s · 点杀护栏=%s · 旗标 moved=%s attacked=%s" % [
			her.hp, (lineA if which == "A" else lineC), "开" if threat else "关",
			n1[0], n1[1], n2[0], n2[1],
			"拦" if push else "放行", "拦" if kill else "放行",
			str(poker.moved), str(poker.attacked)])
		her.silenced = false
		sim.foe_dead = -1
	print("PROBE|END")
	get_tree().quit(0)

## 候选表里"打她"的手数 / 全部手数
func _count(acts: Array, idx_her: int) -> Array:
	var n_her := 0
	for act in acts:
		if int(act.get("atk", -1)) == idx_her:
			n_her += 1
	return [n_her, acts.size()]

## 她的落点圈里有几个我方单位（与 `_redcap_blast_zone()` 同一把尺）
func _zone_count(ai, sim, her) -> int:
	var n := 0
	for v in sim.units:
		if v == null or not v.alive or v.fn == her.fn:
			continue
		if ai._redcap_blast_zone(sim, her, v.cell):
			n += 1
	return n

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
