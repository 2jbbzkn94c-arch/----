extends Node
## 【2026-09-26 一次性探针】炸弹人（hero_35 · 攻 3 · 〈远程〉）**"贴身用 1 伤打血锁、而不退开打 3 伤"**的复刻自检。
##
## 用户实机日志（噩梦 = 模式 2）：
##   `炸弹人：原地打 血锁（约 1 伤）`，而"为什么打的是它"给的备选**全是原地的 1 伤线**
##   ⇒ 候选里**根本没有"退开打 3 伤"那一手**。
##
## 引擎本来就该拦这种情况（`_tp_move_actions()` 里那道闸门，用户上次报"炸弹人贴着雪拳打 1"之后加的）：
##   `if ranged and alt_best > pinned_atk and out.size() > 1 and _sim_enemy_adjacent(sim, u, u.cell)` ⇒ 丢掉"原地"
##   而 `alt_best` 只在"某一手的**开火格不挨着任何敌人**"时才 = 满伤（3）。
##
## 本探针把那个盘面手搓出来，回答两件事：
##   ① **物理上有没有**"不贴身、还能打到血锁"的落点？（有 ⇒ 那一枪本该是 3 伤）
##   ② 有的话，它**有没有进** `_actions_for()`（动作表）与 `_tp_move_actions()`（阶段 1 落点）？
##      · 没进 ⇒ 候选生成/截断的问题（`MAX_MOVE_OPTIONS` / 被占 / 够不到）
##      · 进了却被丢 ⇒ 那道闸门的判据问题
##   最后再跑一次真 `search()`，看它实际选的那一步。
##
## 用法：godot.exe --headless --path <根> --scene res://RL/probe/炸弹人贴身复刻自检.tscn

const FORK := preload("res://RL/ai/AI_Battle.gd")
const WEIGHTS := "res://RL/weights/噩梦.json"

var _grid: HexGrid

func _ready() -> void:
	_grid = HexGrid.new(5, 7, 48.0)
	_grid.top_cap_cols = [1, 3]
	_run.call_deferred()

func _run() -> void:
	var nm := _load_json(WEIGHTS)
	print("PROBE|CFG|fork=%s|weights=%s" % [_sha("res://RL/ai/AI_Battle.gd"), WEIGHTS])
	var descs := _board()
	var occ := {}
	for d in descs:
		occ[d["cell"]] = true
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 8000   # 盘面只有 6 个单位，8 秒足够；30 秒会让探针跑成几分钟
	ai.set_weights(nm)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	print("PROBE|盘面|" + _board_txt(descs))
	var bi := _find(sim, "hero_35")
	var ti := _find(sim, "hero_41")
	if bi < 0 or ti < 0:
		print("PROBE|ERR|盘面里找不到 炸弹人(hero_35) 或 血锁(hero_41)")
		print("PROBE|END")
		get_tree().quit(0)
		return
	var u = sim.units[bi]
	var tgt = sim.units[ti]
	var ranged: bool = u.atk_type == DataRegistry.AttackType.RANGED
	# ⚠️ SimUnit 没有 move_range，是 emove（有效移动力）—— 第一次跑就栽在这上面
	print("PROBE|身板|炸弹人 cell=%s move=%d 射程=%d 远程=%s｜不贴身伤=%d 贴身伤=%d｜血锁 cell=%s hp=%d 距离=%d" % [
		str(u.cell), int(u.emove), int(u.atk_range), str(ranged),
		int(ai._sim_free_atk(u)), int(ai._sim_pinned_atk(u)), str(tgt.cell), int(tgt.hp), _grid.distance(u.cell, tgt.cell)])

	# ---------- ① 全盘扫描：哪些格"不挨着任何敌人 && 能打到血锁" ----------
	var free_hit: Array = []
	var cells := _grid.all_cells()
	for c in cells:
		if sim.occ.has(c) or sim.obstacles.has(c) or sim.graves.has(c):
			continue
		if ai._sim_enemy_adjacent(sim, u, c):
			continue                                   # 站这儿仍被贴身 ⇒ 还是 1 伤
		var hit := false
		for t2 in ai._valid_targets(sim, u, c):
			if int(t2) == ti:
				hit = true
				break
		if hit:
			free_hit.append(c)
	print("PROBE|①不贴身且能打到血锁的格|%d 个：%s" % [free_hit.size(), str(free_hit)])

	# ---------- ② 动作表（`_actions_for`）：退开那一手在不在 ----------
	var acts: Array = ai._actions_for(sim, bi)
	var mv_cells := {}
	var act_txt: Array = []
	for a in acts:
		var mv: Variant = a.get("move")
		var atk := int(a.get("atk", -1))
		var c2: Vector2i = u.cell if mv == null else mv
		var dmg := int(ai._sim_pinned_atk(u)) if ai._sim_enemy_adjacent(sim, u, c2) else int(ai._sim_free_atk(u))
		if mv != null:
			mv_cells[mv] = true
		act_txt.append("%s->atk%d(伤%d)" % ["原地" if mv == null else str(mv), atk, dmg])
	print("PROBE|②_action表|%d 条：%s" % [acts.size(), " ".join(act_txt)])
	var free_in_acts: Array = []
	for c in free_hit:
		if mv_cells.has(c):
			free_in_acts.append(c)
	print("PROBE|②退开格有没有进动作表|%d/%d：%s" % [free_in_acts.size(), free_hit.size(), str(free_in_acts)])

	# ---------- ③ 阶段 1 落点（`_tp_move_actions`）：原地被丢了没、退开格在不在 ----------
	var tp: Array = ai._tp_move_actions(sim, bi)
	var tp_txt: Array = []
	var tp_has_stay := false
	var tp_free: Array = []
	for e in tp:
		var mv2: Variant = e.get("move")
		if mv2 == null:
			tp_has_stay = true
			tp_txt.append("原地")
		else:
			tp_txt.append(str(mv2))
			if free_hit.has(mv2):
				tp_free.append(mv2)
	print("PROBE|③阶段1落点|%d 个：%s" % [tp.size(), " ".join(tp_txt)])
	print("PROBE|③判定|原地被保留=%s｜退开格进了阶段1=%d/%d" % [str(tp_has_stay), tp_free.size(), free_hit.size()])

	# ---------- ④ 真跑一次 search()：它实际选了什么 ----------
	var t0 := Time.get_ticks_msec()
	var plan: Array = ai.search(sim.clone(), DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0
	var step_txt: Array = []
	for st in plan:
		var idx := int(st["idx"])
		if idx < 0 or idx >= sim.units.size():
			continue
		var who = sim.units[idx]
		if who == null:
			continue
		var act: Dictionary = st["action"]
		var mv3: Variant = act.get("move")
		var a3 := int(act.get("atk", -1))
		var tname := "-"
		if a3 >= 0 and a3 < sim.units.size() and sim.units[a3] != null:
			tname = String(sim.units[a3].hero_id)
		if String(who.hero_id) == "hero_35":
			step_txt.append("炸弹人[%s→%s,打%s]" % ["原地" if mv3 == null else str(mv3), ("出手" if a3 >= 0 else "不出手"), tname])
	print("PROBE|④search|思考 %dms｜炸弹人那一步：%s" % [ms, (" ".join(step_txt) if step_txt.size() > 0 else "（没出手/没这步）")])
	print("PROBE|④结论|%s" % _verdict(free_hit.size(), free_in_acts.size(), tp_free.size(), tp_has_stay))
	print("PROBE|END")
	get_tree().quit(0)

func _verdict(n_free: int, n_acts: int, n_tp: int, stay: bool) -> String:
	if n_free == 0:
		return "无处可退（全盘没有'不贴身又能打到血锁'的格）⇒ 贴身打 1 伤是**唯一合法选择**，AI 没错"
	if n_acts == 0:
		return "有 %d 个退开格，但**没进动作表**（`_actions_for`）⇒ 候选生成/截断的问题" % n_free
	if n_tp == 0:
		return "有 %d 个退开格、也进了动作表，但**没进阶段 1 落点**（`_tp_move_actions`）⇒ 阶段 1 那颗闸门/漏斗的问题" % n_free
	return "退开格一路都进了（动作表 %d、阶段1 %d，原地被保留=%s）⇒ 是**评分**没选它（③血量账/④集火/⑥⑦ 的权衡）" % [n_acts, n_tp, str(stay)]

func _board() -> Array:
	# 照截图手搓：我方三人在左上，炸弹人贴着血锁；红帽/长角在右边那一坨
	var out: Array = []
	out.append(_desc(DataRegistry.Faction.ENEMY, "hero_23", Vector2i(1, 2), "复仇者"))
	out.append(_desc(DataRegistry.Faction.ENEMY, "hero_42", Vector2i(1, 3), "黄金矿工"))
	out.append(_desc(DataRegistry.Faction.ENEMY, "hero_35", Vector2i(2, 3), "炸弹人"))
	out.append(_desc(DataRegistry.Faction.PLAYER, "hero_41", Vector2i(2, 2), "血锁"))
	out.append(_desc(DataRegistry.Faction.PLAYER, "hero_40", Vector2i(3, 3), "红帽"))
	out.append(_desc(DataRegistry.Faction.PLAYER, "hero_32", Vector2i(3, 1), "长角"))
	return out

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
func _board_txt(descs: Array) -> String:
	var parts: Array = []
	for d in descs:
		parts.append("%s@%s" % [str(d.get("hero", "?")), str(d["cell"])])
	return " ".join(parts)

func _find(sim, hero_id: String) -> int:
	for i in sim.units.size():
		var su = sim.units[i]
		if su != null and String(su.hero_id) == hero_id:
			return i
	return -1

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

func _sha(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode().substr(0, 12)
