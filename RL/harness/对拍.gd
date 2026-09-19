extends Node
## "基线自检"：同一局面下，**陪练基准副本**（RL/ai/AI_Battle_原版.gd）与生产真身
## （src/BattleAI.gd）必须选出**逐位相同**的行动计划。
##
## 这是前置条件"陪练对手行为必须与单机困难档一致"的证据（决策层）。
## 规则层不用对拍：两者都在真实 scenes/Main.tscn 上跑，规则本来就是同一套。
##
## 为什么默认比"原版"而不是 fork：fork(RL/ai/AI_Battle.gd) 是**带保真修正的候选**，
## 它修掉了墓碑/远近被贴/一次性道具/落停引爆等一批"AI 预判 ≠ 真实规则"的缺口，
## 预测更准 → 选招必然与 src 不同（**预期分叉**，不是回归）。所以：
##   * 基线一致性 → 比 `原版`（默认，必须 all_identical=true）
##   * 候选 vs 基线的差异度量 → 用第二个参数 `cand`（结果不必一致，只看差在哪）
##
## 运行：
##   godot --headless --path <proj> --log-file <log> --scene res://RL/harness/对拍.tscn -- [局面数] [base|cand]
## 输出：EQ|pos=..|seed=..|halves=..|identical=true/false [|mismatch=..]

const REAL := preload("res://src/BattleAI.gd")
const BASE := preload("res://RL/ai/AI_Battle_原版.gd")   # 陪练基准（= src 的原样副本，无 class_name）
const CAND := preload("res://RL/ai/AI_Battle.gd")        # RL 候选（带保真修正）

const P_DECK: Array[String] = ["hero_06", "hero_17", "hero_26"]
const E_DECK: Array[String] = ["hero_13", "hero_12", "hero_23"]
const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const MAX_HALF := 30
const ACT_WALL_MS := 400      # 等一招动画的上限（scale=20 时生产侧等效 150ms；取 400 留余量）

var _b: Battle = null
var _p_deck: Array = P_DECK.duplicate()
var _e_deck: Array = E_DECK.duplicate()
var _diff := 2                # 2 = 困难档（抖动 0，可复现）
var _mode := "base"           # "base" = 比陪练基准副本（默认，基线自检）；"cand" = 比 fork 候选
var _other_script = BASE      # 运行时选定的"第二个 AI"脚本
var _other_path := "res://RL/ai/AI_Battle_原版.gd"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var ua := OS.get_cmdline_user_args()
	var positions := int(ua[0]) if ua.size() > 0 else 4
	if ua.size() > 1 and String(ua[1]) == "cand":
		_mode = "cand"
		_other_script = CAND
		_other_path = "res://RL/ai/AI_Battle.gd"
	var seeds: Array = [1101, 1202, 1303, 1404, 1505, 1606, 1707, 1808]
	print("EQ|start|positions=%d|difficulty=%d|mode=%s|other=%s|other_sha=%s" % [
		positions, _diff, _mode, _other_path, _sha(_other_path)])
	var pass_n := 0
	var checked := 0
	for i in positions:
		var sd: int = seeds[i % seeds.size()]
		var ok := await _scan_game(sd, checked)
		checked += ok["checked"]
		pass_n += ok["pass"]
	print("EQ|SUMMARY|mode=%s|checked=%d|identical=%d|all_identical=%s" % [
		_mode, checked, pass_n, str(checked > 0 and checked == pass_n)])
	print("EQ|END")
	get_tree().quit(0)

## 一局：双方都用脚本 bot 推进，沿途在若干检查点做"计划对拍"
func _scan_game(seed_v: int, so_far: int) -> Dictionary:
	await _setup(seed_v)
	var checked := 0
	var pass_n := 0
	var halves := 0
	while not GameState.match_over and halves < MAX_HALF:
		# 每 2 个半回合对拍一次（覆盖开局/中局/残局）
		if halves % 2 == 0:
			var r := _compare_plans()
			checked += 1
			if bool(r["identical"]):
				pass_n += 1
			print("EQ|pos=%d|seed=%d|halves=%d|identical=%s%s" % [
				so_far + checked - 1, seed_v, halves, str(r["identical"]),
				"" if bool(r["identical"]) else "|mismatch=" + str(r["mismatch"])])
		var side: int = GameState.active_side
		_b.turn_time_left = 0.0
		_b.peer_turn_time_left = 0.0
		await _bot_side(side)
		if GameState.match_over:
			break
		await _b._end_side(side)
		halves += 1
		if _b.state != Battle.State.PLAYER_INPUT and not GameState.match_over:
			var t0 := Time.get_ticks_msec()
			while _b.state != Battle.State.PLAYER_INPUT and not GameState.match_over \
					and Time.get_ticks_msec() - t0 < 30000:
				await get_tree().process_frame
	await _teardown()
	return { "checked": checked, "pass": pass_n }

## 核心：同一快照喂给两个 AI，比较返回的计划
func _compare_plans() -> Dictionary:
	var snap: Dictionary = BattleSnapshot.collect(_b)
	var ai_real = REAL.new(_b.grid)
	ai_real.difficulty = _diff
	ai_real.log_decisions = false
	var ai_fork = _other_script.new(_b.grid)
	ai_fork.difficulty = _diff
	ai_fork.log_decisions = false
	# 两个 AI 各自动建一份 sim（互不共享，避免任何互相污染）
	var s1 = ai_real.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"])
	var s2 = ai_fork.build_state(snap["descs"], snap["occ"], snap["gold"], snap["grave"],
			snap["obstacle"], snap["bomb"], snap["buff"])
	var p1: Array = ai_real.search(s1, DataRegistry.Faction.ENEMY)
	var p2: Array = ai_fork.search(s2, DataRegistry.Faction.ENEMY)
	var t1 := _plan_text(p1)
	var t2 := _plan_text(p2)
	if t1 == t2:
		return { "identical": true, "mismatch": "" }
	# 找出第一处不同，方便定位
	var n := mini(t1.size(), t2.size())
	var k := 0
	while k < n and t1[k] == t2[k]:
		k += 1
	return { "identical": false, "mismatch": "step%d real=%s %s=%s" % [
		k, str(t1[k]) if k < t1.size() else "<none>",
		_mode, str(t2[k]) if k < t2.size() else "<none>"] }

## 把计划转成可比较的字符串序列（含 move/atk/atk_obs 全部字段）
func _plan_text(plan: Array) -> Array:
	var out: Array = []
	for step in plan:
		var a: Dictionary = step.get("action", {})
		out.append("%d:%s:%d:%s" % [
			int(step.get("idx", -1)), str(a.get("move", null)), int(a.get("atk", -99)),
			str(a.get("atk_obs", null))])
	return out

# ---------------- 建局 / 脚本 bot（仅调用现有函数，不修改任何文件） ----------------

func _setup(seed_v: int) -> void:
	Engine.time_scale = 20.0   # 只砍演出等待，不改规则（已逐位验证过）
	GameState.reset_online()
	GameState.dual_control = true      # 双方都停在 PLAYER_INPUT，不自动跑生产 AI
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.match_over = false
	GameState.ai_difficulty = _diff
	GameState.clear_placement()
	for i in P_CELLS.size():
		GameState.player_placement[P_CELLS[i]] = _p_deck[i]
	for i in E_CELLS.size():
		GameState.enemy_placement[E_CELLS[i]] = _e_deck[i]
	GameState.player_deck = _p_deck.duplicate()
	GameState.enemy_deck = _e_deck.duplicate()
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(seed_v)
	_b._first_side = GameState.SIDE_PLAYER
	get_tree().root.add_child(_b)
	var t0 := Time.get_ticks_msec()
	while _b.state != Battle.State.PLAYER_INPUT and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame

func _teardown() -> void:
	Engine.time_scale = 1.0
	if _b != null and is_instance_valid(_b):
		_b.queue_free()
	_b = null
	await get_tree().process_frame
	await get_tree().process_frame

func _act_and_wait(cb: Callable) -> void:
	var done: Array = [false]
	var h := func() -> void: done[0] = true
	_b.action_finished.connect(h, CONNECT_ONE_SHOT)
	cb.call()
	var t0 := Time.get_ticks_msec()
	while not done[0] and Time.get_ticks_msec() - t0 < ACT_WALL_MS:
		await get_tree().process_frame
	if not done[0] and is_instance_valid(_b) and _b.action_finished.is_connected(h):
		_b.action_finished.disconnect(h)

func _bot_side(side: int) -> void:
	var fn := _b.side_faction(side)
	for u in _b.units.duplicate():
		if GameState.match_over:
			return
		if u == null or not is_instance_valid(u) or not u.alive or u.faction != fn:
			continue
		if u.can_attack() and not u.attacked_this_turn:
			var t := _pick_target(u, fn)
			if t != null:
				await _act_and_wait(func() -> void: _b._do_attack(u, t, true))
				continue
		if u.can_move() and not u.moved_this_turn:
			var dest := _pick_move(u, fn)
			if dest.x >= 0:
				await _act_and_wait(func() -> void: _b._do_move(u, dest, true))
				if is_instance_valid(u) and u.alive and u.can_attack() and not u.attacked_this_turn:
					var t2 := _pick_target(u, fn)
					if t2 != null:
						await _act_and_wait(func() -> void: _b._do_attack(u, t2, true))

func _pick_target(u: Unit, fn: int) -> Unit:
	var best: Unit = null
	for t in _b.units:
		if t == null or not is_instance_valid(t) or not t.alive or t.faction == fn:
			continue
		if not _b._in_attack_range(u, t):
			continue
		if best == null or t.hp < best.hp:
			best = t
	return best

func _pick_move(u: Unit, fn: int) -> Vector2i:
	var keys: Array = []
	for c in _b._move_reachable(u).keys():
		if not _b.occupancy.has(c):
			keys.append(c)
	keys.sort_custom(func(a, b) -> bool: return (a.y * 100 + a.x) < (b.y * 100 + b.x))
	var best := Vector2i(-99, -99)
	var best_d := 1 << 29
	for c in keys:
		var d := _nearest_foe_dist(c, fn)
		if d < best_d:
			best_d = d
			best = c
	return best

func _nearest_foe_dist(cell: Vector2i, fn: int) -> int:
	var best := 1 << 29
	for t in _b.units:
		if t == null or not is_instance_valid(t) or not t.alive or t.faction == fn:
			continue
		best = mini(best, _b.grid.distance(cell, t.cell))
	return best

func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "?"
	var ctx := HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256) != OK:
		return "?"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	ctx.update(f.get_buffer(f.get_length()))
	f.close()
	return ctx.finish().hex_encode().substr(0, 12)
