extends Node
## 【2026-09-29 深夜·一次性探针·只读·A/B】用户口径「能不能把这种 AI 都发现自己意思被剪的项
##   也加入到评估，最后根据评分选路径」的读数 —— 键 `PROMISE_REPAIR`（"认账补手"）。
##
## 盘面：`RL/probe/最小链检.gd` 那块（用户实机那局的复刻），只加**障碍/墓碑/金矿**两种变体
##   ⇒ 三块盘面各跑三档，**同一局面、同一预算**：
##     ① 复查关·补手关（= 现状，基线）
##     ② 复查开·补手关（= 只有 `TWO_PHASE_POLISH`）
##     ③ 复查开·补手开（= 本键，用户要的方向）
##   三档都走**生产那条路**（`ai.search()` 一调用到底、复查/补手在它内部按 `TIME_BUDGET_MS` 收尾），
##   差别只有两个键的开合 ⇒ 读数可直接比。
##   每档记：**实测末态分**（探针自己 `_plan_score` 重算，与引擎选计划同一把尺子）/ 墙钟 /
##   阶段 1·2 评分数 / 补手试了几手·换成几手·赚几分 / **这份最终计划里还剩几笔"本可多赚"没还**。
##
## 输出：FIX|CFG / FIX|POS / FIX|欠 / FIX|SUM / FIX|END

const BOARDS := [
	{ "tag": "A(原盘面)", "obs": [[0, 3], [4, 3], [0, 4], [4, 4]], "grave": [], "gold": [] },
	{ "tag": "B(有障碍挡路)", "obs": [[2, 3], [1, 4], [3, 5]], "grave": [], "gold": [] },
	{ "tag": "C(有墓碑+金矿)", "obs": [[0, 4], [4, 4]], "grave": [[1, 5]], "gold": [[3, 4]] },
]
## 单档预算（含复查/补手那段收尾；生产噩梦是 40000）
const SEARCH_TIME_MS := 30000

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var nm := _load_json("res://RL/weights/噩梦.json")
	print("FIX|CFG|噩梦权重键=%d｜PROMISE_REPAIR(权重文件)=%s｜预算=%dms｜fork=%s" % [
		nm.size(), str(nm.get("PROMISE_REPAIR", "(没写这行)")), SEARCH_TIME_MS,
		_sha("res://RL/ai/AI_Battle.gd")])
	var total := { "base": 0.0, "polish": 0.0, "repair": 0.0,
		"warn_base": 0, "warn_pol": 0, "warn_rep": 0, "swaps": 0, "tried": 0 }
	for bi in BOARDS.size():
		var board: Dictionary = BOARDS[bi]
		var ai = await _rebuild(board)
		if ai == null:
			print("FIX|%s|拿不到 AI" % String(board["tag"]))
			continue
		var r1: Dictionary = _arm(ai, nm, 0, 0)   # ① 基线
		var r2: Dictionary = _arm(ai, nm, 1, 0)   # ② 只复查
		var r3: Dictionary = _arm(ai, nm, 1, 1)   # ③ 复查 + 补手
		for r in [r1, r2, r3]:
			print("FIX|POS|%s|%s|末态分=%.2f|墙钟=%dms|阶段1评分=%d|阶段2评分=%d|补手试=%d|补手换=%d|补手+%.1f|还欠账=%d|计划=%s" % [
				String(board["tag"]), String(r["cfg"]), float(r["score"]), int(r["ms"]),
				int(r["p1"]), int(r["p2"]), int(r["tried"]), int(r["swaps"]), float(r["gain"]),
				int(r["warn"]), String(r["steps"])])
			for wl in (r["warn_lines"] as Array):
				print("FIX|欠|%s|%s|%s" % [String(board["tag"]), String(r["cfg"]), String(wl)])
		total["base"] += float(r1["score"])
		total["polish"] += float(r2["score"])
		total["repair"] += float(r3["score"])
		total["warn_base"] += int(r1["warn"])
		total["warn_pol"] += int(r2["warn"])
		total["warn_rep"] += int(r3["warn"])
		total["swaps"] += int(r3["swaps"])
		total["tried"] += int(r3["tried"])
	print("FIX|SUM|板面=%d｜基线=%.2f｜只复查=%.2f(%+.2f)｜复查+补手=%.2f(%+.2f)｜补手换手=%d/%d 手试评｜还欠账 %d → %d → %d｜末态分口径=末态 `_evaluate(s,true)` − 闲置罚" % [
		BOARDS.size(), float(total["base"]), float(total["polish"]),
		float(total["polish"]) - float(total["base"]), float(total["repair"]),
		float(total["repair"]) - float(total["base"]), int(total["swaps"]), int(total["tried"]),
		int(total["warn_base"]), int(total["warn_pol"]), int(total["warn_rep"])])
	print("FIX|END")
	get_tree().quit(0)

## 跑一档：`ai.search()` 一调用到底（复查/补手在它内部按 `TIME_BUDGET_MS` 收尾），
##   然后探针**自己**把交出来的计划回放 → `_plan_score` 重算末态分（独立于引擎的记账）。
func _arm(ai, nm: Dictionary, polish: int, repair: int) -> Dictionary:
	var w := { "TIME_BUDGET_MS": SEARCH_TIME_MS, "TWO_PHASE_POLISH": polish, "PROMISE_REPAIR": repair }
	for k in nm.keys():
		w[k] = nm[k]
	w["TIME_BUDGET_MS"] = SEARCH_TIME_MS   # 覆盖权重文件，保证三档同一预算
	w["TWO_PHASE_POLISH"] = polish
	w["PROMISE_REPAIR"] = repair
	ai.set_weights(w)
	ai.log_decisions = false
	var snap := BattleSnapshot.collect(battle)
	var sim = ai.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"], -1, snap.get("rosters", {}), {}, snap.get("buff_owner", {}))
	# ⚠️ 三档共用同一个探针进程 ⇒ 上一档的 `_print_decision()` 会在 `sim` 上留下走位缓存
	#   （`walk_cache` / `walk_cache_pass` / 记忆化表）⇒ 这一档的搜索从"热缓存"起步，
	#   与上一档的"冷缓存"不同基准（实测同一盘面两轮读数 118.60 / 126.88 就是这么来的）。
	#   ⇒ 每档开跑前清干净，保证三档**同一基准**。
	sim.walk_cache = {}
	sim.walk_cache_pass = {}
	ai._inc_memo = {}
	# 闲置罚要的那两张表：照 `_search_two_phase()` 开头的口径自己算一遍（回合开始快照）
	var eidx: Array = _enemy_idxs(sim)
	var can_hit: Dictionary = {}
	var targets: Dictionary = {}
	for i in eidx:
		var tg: Array = []
		for a0 in ai._actions_for(sim, int(i)):
			var t0 := int(a0.get("atk", -1))
			if t0 >= 0 and not tg.has(t0):
				tg.append(t0)
		can_hit[i] = tg.size() > 0
		targets[i] = tg
	var t0m := Time.get_ticks_msec()
	var plan: Array = ai.search(sim, DataRegistry.Faction.ENEMY)
	var ms := Time.get_ticks_msec() - t0m
	# 实测末态分：探针自己回放计划（`_plan_score` 与引擎末态选计划同一把尺子）
	var end_sim = ai._plan_end_state(sim, plan)
	var score := float(ai._plan_score(end_sim, plan, eidx, can_hit, targets))
	var steps: Array = []
	for st in plan:
		var a: Dictionary = st["action"]
		var ui := int(st["idx"])
		var un := String(sim.units[ui].name) if ui >= 0 and ui < sim.units.size() else "?"
		var atk := int(a.get("atk", -1))
		if atk == -2:
			steps.append("%s敲障碍%s" % [un, str(a.get("atk_obs", "?"))])
		elif atk >= 0:
			var tn := String(sim.units[atk].name) if atk < sim.units.size() else "?"
			steps.append(("%s原地打%s" % [un, tn]) if a.get("move", null) == null \
				else ("%s走%s打%s" % [un, str(a.get("move")), tn]))
		elif a.get("move", null) != null:
			steps.append("%s走到%s" % [un, str(a.get("move"))])
		else:
			steps.append("%s不出手" % un)
	# 把**最终计划**喂回日志，数它自己认了几笔"本可多赚"（= 还剩多少没还）
	ai.log_decisions = true
	var chosen := { "path": plan, "score": score, "sim": end_sim, "done": {}, "tb": [] }
	ai._print_decision(sim, chosen)
	var warn := _count_warn(ai.last_decision_text)
	var warn_lines := _warn_lines(ai.last_decision_text)
	ai.log_decisions = false
	return {
		"cfg": "复查%s·补手%s" % [("开" if polish > 0 else "关"), ("开" if repair > 0 else "关")],
		"score": score, "ms": ms, "steps": " → ".join(steps),
		"p1": int(ai.last_tp_p1_evals), "p2": int(ai.last_tp_p2_evals),
		"tried": int(ai.last_repair_tried), "swaps": int(ai.last_repair_swaps),
		"gain": float(ai.last_repair_gain), "warn": warn, "warn_lines": warn_lines,
	}

func _enemy_idxs(sim) -> Array:
	var out: Array = []
	for i in sim.units.size():
		var u = sim.units[i]
		if u != null and u.alive and int(u.fn) == int(DataRegistry.Faction.ENEMY):
			out.append(i)
	return out

## 日志里「疑似被搜索漏掉（剪枝）」出现几次（= 引擎自己认了几笔账）
func _count_warn(txt: String) -> int:
	var n := 0
	var pos := 0
	while true:
		var p := txt.find("疑似被搜索漏掉", pos)
		if p < 0:
			break
		n += 1
		pos = p + 1
	return n

## 每一条"本可多赚"的行（= 这份**最终计划**里还剩几笔认账没还）
func _warn_lines(txt: String) -> Array:
	var out: Array = []
	for ln in txt.split("\n"):
		var s := String(ln).strip_edges()
		# ⚠️ 只认**警告那两行**（"疑似被搜索漏掉…" / "⚠️ 有备选比它更值…"）；
		#   不能拿"本可多赚"当关键字 —— `[搜索分账]` 里我那句"补手（把「本可多赚」那些手…）"也含它。
		if s.find("疑似被搜索漏掉") >= 0 or s.find("有备选比它更值") >= 0:
			out.append(s)
	return out

## 重建一块盘面（配方照 `RL/probe/最小链检.gd`，只加障碍/墓碑/金矿变体）
func _rebuild(board: Dictionary):
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
	_s("hero_18", DataRegistry.Faction.ENEMY, Vector2i(2, 6), 7)    # 长剑
	_s("hero_40", DataRegistry.Faction.ENEMY, Vector2i(1, 5), 11)   # 红帽
	_s("hero_15", DataRegistry.Faction.ENEMY, Vector2i(2, 4), 18)   # 小阴影
	_s("hero_30", DataRegistry.Faction.PLAYER, Vector2i(1, 3), 11)  # 嬉皮死神
	_s("hero_41", DataRegistry.Faction.PLAYER, Vector2i(3, 3), 11)  # 血锁
	_s("hero_44", DataRegistry.Faction.PLAYER, Vector2i(2, 5), 1)   # 负墟（1 血）
	for o in board["obs"]:
		battle.obstacles[Vector2i(int(o[0]), int(o[1]))] = 2
	for g in board["grave"]:
		battle.graves[Vector2i(int(g[0]), int(g[1]))] = { "fn": int(DataRegistry.Faction.PLAYER), "hero": "hero_40" }
	for gd in board["gold"]:
		battle.buff_items[Vector2i(int(gd[0]), int(gd[1]))] = "gold"
	battle.player_dead = 1
	battle.enemy_dead = 2
	for i in 3:
		await get_tree().process_frame
	battle._sync_ranged_adjacent()
	var ai = battle._make_battle_ai()
	if ai == null:
		return null
	ai.difficulty = 3
	return ai

func _s(hid: String, fn, cell: Vector2i, hp: int) -> void:
	var u = battle._spawn_unit(hid, fn, cell)
	if u != null:
		u.hp = hp

func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func _sha(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "nofile"
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
