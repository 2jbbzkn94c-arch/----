extends Node
## 【2026-09-26 一次性探针·临时】"**能直接斩杀，却先拿低攻的打一下吃个反击**" —— 用户实机报的症状。
##   要回答的是：**这是定价问题还是搜索问题**。
##
## 盘面（7×5）：**高攻8** 与 **低攻3** 都已经贴着 **残血目标**（8 血）。两个人都能原地出手 ⇒
##   **唯一的变量就是出手顺序**：
##     序 A 低攻先打 ⇒ 目标剩 5 ⇒ **目标反击**给低攻（伤害 = 目标的攻，× 低攻的**血量池倍率**）⇒ 高攻补刀
##     序 B 高攻先杀 ⇒ 目标直接死（**0 反击**）⇒ 低攻这一手没得打 ⇒ 若"不打"要付 `IDLE_HIT_PENALTY`(2.0)
##   ⇒ 引擎偏好哪一序，取决于「**反击那点血 × 池倍率**」与「**少打一手的罚 2.0**」谁大。
##
## 三个盘面扫这两个数（预期：只有①这种"坦克吃小反击"才会翻过去）：
##   ① 低攻 20 血（池 1.00）· 目标 4 攻 ⇒ 反击 4.0 > 罚 2.0 ⇒ 应选 **B 高攻先杀**
##   ② 低攻 33 血（池 0.61）· 目标 3 攻 ⇒ 反击 1.82 < 罚 2.0 ⇒ **怀疑实机就是这个 ⇒ 会选 A**
##   ③ 低攻 33 血（池 0.61）· 目标 6 攻 ⇒ 反击 3.64 > 罚 2.0 ⇒ 应选 **B**
##
## 每盘面打印：AI 计划（按执行顺序）· 两个顺序各自 `_evaluate(末态)` 总分 · 主要评分项。
## 输出：每行 `ORD|...`，末尾 `ORD|END`。

const FORK := preload("res://RL/ai/AI_Battle.gd")
const NIGHTMARE_PATH := "res://RL/weights/噩梦.json"

var _grid: HexGrid
var _w: Dictionary = {}
var _logf: FileAccess = null

## 【诊断】同时写一份到文件：万一下面的搜索卡住（进程被杀时 stdout 不会 flush），
##   也还能从文件看到**卡在哪一步**。
func _log(s: String) -> void:
	print(s)
	if _logf == null:
		_logf = FileAccess.open("res://.godot_userdata/_ko_probe.log", FileAccess.WRITE)
	if _logf != null:
		_logf.store_line(s)
		_logf.flush()

func _ready() -> void:
	_grid = HexGrid.new()
	_grid.width = 7
	_grid.height = 5
	_run.call_deferred()

func _run() -> void:
	_w = _load_flat_weights(NIGHTMARE_PATH)
	_log("ORD|CFG|fork=%s|IDLE_HIT_PENALTY=%.1f|HP_VALUE_W=%.2f|INCOMING_POOL_W=%.2f|TRADE_HP_REF=%d|BEAM=%d|SEARCH_MODE=%d" % [
		_sha("res://RL/ai/AI_Battle.gd"), float(_w.get("IDLE_HIT_PENALTY", 0.0)),
		float(_w.get("HP_VALUE_W", 1.0)), float(_w.get("INCOMING_POOL_W", 0.0)),
		int(_w.get("TRADE_HP_REF", 20)), int(_w.get("BEAM", 0)), int(_w.get("SEARCH_MODE", 0))])
	_scenario("① 低攻20血 · 目标4攻 ⇒ 反击4.0 vs 罚2.0", 20, 4)
	_scenario("② 低攻33血 · 目标3攻 ⇒ 反击1.82 vs 罚2.0", 33, 3)
	_scenario("③ 低攻33血 · 目标6攻 ⇒ 反击3.64 vs 罚2.0", 33, 6)
	_log("ORD|END")
	get_tree().quit(0)

func _scenario(tag: String, low_hp: int, foe_atk: int) -> void:
	_log("ORD|%s|开始" % tag)
	var E := DataRegistry.Faction.ENEMY
	var P := DataRegistry.Faction.PLAYER
	var MELEE := int(DataRegistry.AttackType.MELEE)
	var descs := [
		_u(E, "hero_26", Vector2i(2, 3), 24, 24, 8, 3, 1, MELEE, [], "高攻8"),
		_u(E, "hero_23", Vector2i(1, 4), low_hp, low_hp, 3, 3, 1, MELEE, [], "低攻3"),
		_u(P, "hero_18", Vector2i(2, 4), 8, 8, foe_atk, 3, 1, MELEE, [], "残血目标8"),
	]
	var occ := {}
	for i in descs.size():
		occ[descs[i]["cell"]] = i
	var ai = _mk_ai(_w)
	var sim = ai.build_state(descs, occ, {}, {}, {}, {}, {})
	var pool := 1.0 + float(_w.get("INCOMING_POOL_W", 0.0)) * (clampf(
		float(int(_w.get("TRADE_HP_REF", 20))) / float(low_hp), 0.5, 3.0) - 1.0)
	_log("ORD|%s|低攻池倍率=%.2f ⇒ 预期反击成本=%.2f" % [tag, pool, float(foe_atk) * pool])
	var path: Array = ai.search(sim, E)
	_log("ORD|%s|搜索完成（%d 步）" % [tag, path.size()])
	var order: Array[String] = []
	for st in path:
		var idx := int((st as Dictionary)["idx"])
		var a: Dictionary = (st as Dictionary)["action"]
		var atk := int(a.get("atk", -1))
		var what := ("打 " + str(sim.units[atk].name)) if atk >= 0 and atk < sim.units.size() else "不出手"
		if a.get("move") != null:
			what = "走到 %s，%s" % [str(a["move"]), what]
		order.append("%s（%s）" % [str(sim.units[idx].name), what])
	_log("ORD|%s|AI 选的顺序：%s" % [tag, " → ".join(order)])
	_cmp(ai, sim, 1, 0, 2, "%s｜A 低攻先打 → 高攻斩杀" % tag)
	_cmp(ai, sim, 0, 1, 2, "%s｜B 高攻先杀 → 低攻不打" % tag)

## 依次让 `first` → `second` 打目标 `tgt`；若轮到某人时已经打不到（目标已死），就当作"不打"并按引擎口径
##   补上 `IDLE_HIT_PENALTY`（阶段 2 `idle_hit` 那一段：判据 = 该单位本回合**开始时**能不能打到人）。
func _cmp(ai, sim, first: int, second: int, tgt: int, tag: String) -> void:
	var s = sim.clone()
	var idle := 0.0
	for idx in [first, second]:
		var act := _find_atk(ai, s, idx, tgt)
		if act.is_empty():
			# 【2026-09-27 新口径】"不打"要付罚，**但只有当它本来能打的目标还有活着的**
			#   （本盘面里它唯一能打的目标就是 `tgt`；目标已被队友杀掉 ⇒ 这一手本来没意义 ⇒ 不罚）。
			var tgt_alive: bool = s.units[tgt] != null and (s.units[tgt] as Object).get("alive") == true
			if tgt_alive:
				idle += float(_w.get("IDLE_HIT_PENALTY", 0.0))
			continue
		ai._apply(s, idx, act)
	var sc := float(ai._evaluate(s, true)) - idle
	var bits: Array[String] = []
	var bd: Dictionary = ai._eval_breakdown(s, true)
	var keys: Array = bd.keys()
	keys.sort_custom(func(a, b): return absf(float(bd[a])) > absf(float(bd[b])))
	for k2 in mini(5, keys.size()):
		bits.append("%s %+.2f" % [String(keys[k2]), float(bd[keys[k2]])])
	_log("ORD|%s|总分=%.2f（含少打一手的罚 %.1f）｜我方血=%s｜主要项：%s" % [tag, sc, idle,
		_hp(s), " · ".join(bits)])

func _find_atk(ai, s, idx: int, tgt: int) -> Dictionary:
	for a in ai._actions_for(s, idx):
		if int(a.get("atk", -1)) == tgt and a.get("move") == null:
			return a
	return {}

func _hp(s) -> String:
	var bits: Array[String] = []
	for u in s.units:
		if u == null or not u.alive or u.fn != DataRegistry.Faction.ENEMY:
			continue
		bits.append("%s %d" % [str(u.name), int(u.hp)])
	return "／".join(bits)

func _u(fn: int, hero: String, cell: Vector2i, hp: int, max_hp: int, atk: int,
		mv: int, rng: int, typ: int, skills: Array, nm: String) -> Dictionary:
	return {
		"fn": fn, "hero": hero, "cell": cell, "hp": hp, "max_hp": max_hp,
		"atk": atk, "eatk": atk, "move": mv, "emove": mv,
		"atk_range": rng, "atk_type": typ, "skills": skills, "name": nm,
	}

func _mk_ai(inject: Dictionary):
	var ai = FORK.new(_grid)
	ai.difficulty = 3
	ai.log_decisions = false
	ai.time_budget_ms = 4000      # 【诊断】别让它无上限地搜（第一版没设 ⇒ 三个盘面连跑时卡死过）
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
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
