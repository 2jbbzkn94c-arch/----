extends Node
## 【2026-09-24 一次性探针】天梯"中局续档"端到端自检（不改生产代码，只跑真实 Battle 场景）：
##   ① 建一局天梯（`ladder_mode="normal"` + 自由部署放置路径，双控 ⇒ 敌方回合不跑生产 AI）
##   ② 等 `_begin_side()` 把快照写进 `LadderStore`（= 回合开始存档点）
##   ③ 模拟"退出"：把战斗场景整棵释放
##   ④ 重新 instantiate 一局（同一份存档）⇒ 应当走 `_ladder_restore()` 而不是重新开局
##   ⑤ 逐字段比对：**续档后重新落盘的快照** 与 退出前那份 是否一致（单位/棋盘实体/账本/卡组/回合）
## 用法：godot --headless --path . --scene res://RL/probe/天梯续档自检.tscn
## 退出码 0 = 全过。

const MainScene := preload("res://scenes/Main.tscn")

const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const P_DECK: Array = ["hero_13", "hero_12", "hero_23"]
const E_DECK: Array = ["hero_06", "hero_17", "hero_26"]
const READY_WALL_MS := 30000

var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 20.0
	LadderStore.finish_run(LadderStore.MODE_NORMAL)   # 先清干净，避免受上一次残留影响
	LadderStore.begin(LadderStore.MODE_NORMAL, P_DECK)
	GameState.ladder_mode = "normal"
	GameState.dual_control = true        # 敌方回合由本端"操控"⇒ 不跑生产 AI，测试可复现
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.ai_difficulty = LadderStore.LOCKED_DIFFICULTY
	GameState.match_over = false
	GameState.clear_placement()
	for i in P_CELLS.size():
		GameState.player_placement[P_CELLS[i]] = P_DECK[i]
	for i in E_CELLS.size():
		GameState.enemy_placement[E_CELLS[i]] = E_DECK[i]
	GameState.player_deck = P_DECK.duplicate()
	GameState.enemy_deck = E_DECK.duplicate()

	# ---- 第一局：等到快照落盘 ----
	var b1 := await _build_battle(1)
	if b1 == null:
		_report(false, "第一局没跑起来")
		return
	var t0 := Time.get_ticks_msec()
	while not LadderStore.has_snapshot() and Time.get_ticks_msec() - t0 < READY_WALL_MS:
		await get_tree().process_frame
	if not LadderStore.has_snapshot():
		_report(false, "回合开始没落盘（快照为空）")
		return
	var snapA: Dictionary = LadderStore.snapshot().duplicate(true)
	print("PROBE|① 第一局落盘：第 %d 回合 · side=%d · 单位 %d · 障碍 %d · 道具 %d · 墓碑 %d" % [
		int(snapA.get("round", -1)), int(snapA.get("side", -1)), (snapA.get("units", []) as Array).size(),
		(snapA.get("obstacles", {}) as Dictionary).size(), (snapA.get("buff_items", {}) as Dictionary).size(),
		(snapA.get("graves", {}) as Dictionary).size()])

	# ---- 模拟退出：整棵释放战斗场景 ----
	b1.queue_free()
	for i in 8:
		await get_tree().process_frame
	print("PROBE|② 已模拟退出（战斗场景释放）· 存档还在吗 = %s" % str(LadderStore.has_run()))

	# ---- 第二局：应当走续档 ----
	var b2 := await _build_battle(2)
	if b2 == null:
		_report(false, "第二局（续档）没跑起来")
		return
	# ⚠️ 必须**立刻**取快照：`_ladder_restore()` → `_begin_side()` 开头就会写一份新的（= 续档后的状态），
	#    若这时还等着"我方输入"，无人操作的回合会因超时自动推进、把快照覆盖成第 N 回合的。
	var snapB: Dictionary = LadderStore.snapshot().duplicate(true)
	var resumed := GameState.round_number == int(snapA.get("round", -1))
	print("PROBE|③ 续档后落盘：第 %d 回合 · side=%d · 单位 %d · 障碍 %d · 道具 %d · 墓碑 %d · 回合号与退出前一致=%s" % [
		int(snapB.get("round", -1)), int(snapB.get("side", -1)), (snapB.get("units", []) as Array).size(),
		(snapB.get("obstacles", {}) as Dictionary).size(), (snapB.get("buff_items", {}) as Dictionary).size(),
		(snapB.get("graves", {}) as Dictionary).size(), str(resumed)])
	if not resumed:
		_fail += 1
		print("PROBE|  ✗ 续档没有回到退出前的回合（第 %d 回合 ≠ 第 %d 回合）" % [GameState.round_number, int(snapA.get("round", -1))])

	# ---- 逐字段比对 ----
	for k in ["round", "side", "player_deck", "enemy_deck", "player_roster", "enemy_roster",
			"player_dead", "enemy_dead", "bombs", "obstacles", "buff_items", "buff_owner",
			"graves", "gold_left", "rng_state", "opening_items_spawned"]:
		_cmp(k, snapA.get(k), snapB.get(k))
	# 单位：按 (阵营, 格) 排序后逐项比 hero_id / hp / 位置 / 状态
	_cmp("units", _unit_rows(snapA), _unit_rows(snapB))

	# ---- ④ 连胜记账链路（直接走 `_emit_match_result()`，与真实判胜同一条路）----
	var lk := Stats.ladder_key(false)
	var keep := { "w": Stats.win_count(lk), "l": Stats.loss_count(lk), "b": Stats.best_streak(lk), "c": Stats.current_streak(lk) }
	Stats.reset_streak(lk)
	b2._emit_match_result(GameState.SIDE_PLAYER)   # 模拟"本端胜"
	var after_win_cur := Stats.current_streak(lk)
	var after_win_best := Stats.best_streak(lk)
	var run_kept := LadderStore.has_run()
	var snap_cleared := not LadderStore.has_snapshot()
	print("PROBE|④ 胜一局：当前连胜=%d · 最高=%d · 本轮还在=%s · 快照已清=%s" % [
		after_win_cur, after_win_best, str(run_kept), str(snap_cleared)])
	if after_win_cur != 1 or after_win_best < 1 or not run_kept or not snap_cleared:
		_fail += 1
		print("PROBE|  ✗ 胜利记账不对")
	b2._emit_match_result(GameState.SIDE_ENEMY)   # 模拟"本端负"
	print("PROBE|④ 输一局：当前连胜=%d · 最高=%d · 本轮还在=%s" % [
		Stats.current_streak(lk), Stats.best_streak(lk), str(LadderStore.has_run())])
	if Stats.current_streak(lk) != 0 or LadderStore.has_run():
		_fail += 1
		print("PROBE|  ✗ 失败没有结束本轮天梯")
	# 还原本轮测试前的战绩（别把用户统计写脏）
	Stats.wins[lk] = keep["w"]
	Stats.losses[lk] = keep["l"]
	Stats.best_streaks[lk] = keep["b"]
	Stats.cur_streaks[lk] = keep["c"]
	Stats._save()

	b2.queue_free()
	for i in 4:
		await get_tree().process_frame

	# ---- ⑤ 续档后轮到噩梦 AI 行动（真实天梯最常见的情形：退出时是敌方回合）----
	LadderStore.begin("normal", P_DECK)
	snapA["side"] = GameState.SIDE_ENEMY   # 把存档点改成"敌方回合开始"
	LadderStore.save_snapshot(snapA)
	GameState.dual_control = false         # 敌方回合真跑生产 AI
	GameState.ai_difficulty = LadderStore.LOCKED_DIFFICULTY   # 噩梦档（会 load RL/ai/AI_Battle.gd）
	var b3 := await _build_battle(3)
	if b3 == null:
		_report(false, "第三局（噩梦 AI 续档）没跑起来")
		return
	var t1 := Time.get_ticks_msec()
	while b3.state != Battle.State.PLAYER_INPUT and not GameState.match_over \
			and Time.get_ticks_msec() - t1 < 60000:
		await get_tree().process_frame
	var alive_n := 0
	for u in b3.units:
		if u != null and is_instance_valid(u) and u.alive:
			alive_n += 1
	print("PROBE|⑤ 噩梦 AI 从续档点跑完敌方回合：state=%d · 存活单位=%d · 对局结束=%s（耗时 %.1fs）" % [
		b3.state, alive_n, str(GameState.match_over), (Time.get_ticks_msec() - t1) / 1000.0])
	if b3.state != Battle.State.PLAYER_INPUT and not GameState.match_over:
		_fail += 1
		print("PROBE|  ✗ 敌方回合没跑完（卡住）")
	b3.queue_free()
	for i in 4:
		await get_tree().process_frame

	# ---- ⑥ 部署阶段退出 ⇒ 再进来直接回到部署（用户报「第2局部署界面退出去，再进来是普通模式选人界面」）----
	LadderStore.finish_run(LadderStore.MODE_NORMAL)
	LadderStore.begin(LadderStore.MODE_NORMAL, P_DECK)
	LadderStore.note_match_started(P_DECK, E_DECK)      # 模拟"进了部署"这一钩子
	LadderStore.clear_snapshot(LadderStore.MODE_NORMAL) # 部署阶段还没有回合快照
	GameState.player_placement.clear()
	GameState.enemy_placement.clear()
	GameState.pick_deck_in_battle = true                # 与 Menu 里那条路由一致
	var b6 := await _build_battle(6)
	var deploy_ok: bool = b6 != null and b6.state == Battle.State.DEPLOY
	var deck_ok: bool = GameState.player_deck == P_DECK and GameState.enemy_deck == E_DECK
	var pending: bool = LadderStore.has_pending_match()
	print("PROBE|⑥ 部署阶段退出后再进：state=%d（DEPLOY=%d）· 卡组=%s vs %s · 记为未打完=%s" % [
		-1 if b6 == null else int(b6.state), int(Battle.State.DEPLOY),
		str(GameState.player_deck), str(GameState.enemy_deck), str(pending)])
	if not (deploy_ok and deck_ok):
		_fail += 1
		print("PROBE|  ✗ 没有直接用原卡组回到部署")
	# ⑥b 「放弃本次天梯」要先弹再确认（用户要求）：这一步不能碰存档
	var hud = null
	for c in b6.get_children() if b6 != null else []:
		if c is HUD:
			hud = c
	if hud != null:
		hud._on_ladder_give_up()
		await get_tree().process_frame
		var confirm_up: bool = hud._ladder_confirm != null and is_instance_valid(hud._ladder_confirm)
		var still_there: bool = LadderStore.has_run(LadderStore.MODE_NORMAL)
		print("PROBE|⑥b 放弃再确认：确认层弹出=%s · 本轮还在=%s（都应 true）" % [str(confirm_up), str(still_there)])
		if not (confirm_up and still_there):
			_fail += 1
			print("PROBE|  ✗ 放弃没有走再确认")
		hud._close_ladder_confirm()
		await get_tree().process_frame
		var closed: bool = hud._ladder_confirm == null
		print("PROBE|⑥b 取消后：确认层已收=%s · 本轮还在=%s（都应 true）" % [str(closed), str(LadderStore.has_run(LadderStore.MODE_NORMAL))])
		if not closed:
			_fail += 1
	else:
		_fail += 1
		print("PROBE|  ✗ 拿不到 HUD，没法验放弃确认")
	if b6 != null:
		b6.queue_free()
		for i in 4:
			await get_tree().process_frame
	# 打完这一局（快照会重新落盘）⇒ 标记应回到"不在对局中"
	LadderStore.finish_run(LadderStore.MODE_NORMAL)
	Stats.reset_streak(Stats.ladder_key(false))
	Engine.time_scale = 1.0
	_report(_fail == 0, "有 %d 项不一致" % _fail)

func _build_battle(seed_v: int) -> Battle:
	var b := MainScene.instantiate() as Battle
	b.set_random_seed(seed_v)
	b._first_side = GameState.SIDE_PLAYER
	get_tree().root.add_child(b)
	var t0 := Time.get_ticks_msec()
	while b.state == Battle.State.IDLE and Time.get_ticks_msec() - t0 < READY_WALL_MS:
		await get_tree().process_frame
	return b

func _unit_rows(snap: Dictionary) -> Array:
	var rows: Array = []
	for rec in (snap.get("units", []) as Array):
		var d: Dictionary = (rec as Dictionary).get("vars", {})
		rows.append("%s@%s/hp%d/f%d/atk%d/st%s" % [
			str(d.get("hero_id", "?")), str(d.get("cell", "?")), int(d.get("hp", -1)), int(d.get("faction", -1)),
			int(d.get("atk", -1)), str(d.get("statuses", {}))])
	rows.sort()
	return rows

func _cmp(k: String, a, b) -> void:
	var sa := str(a)
	var sb := str(b)
	if sa == sb:
		print("PROBE|  ✓ %s" % k)
	else:
		_fail += 1
		print("PROBE|  ✗ %s\n      退出前: %s\n      续档后: %s" % [k, sa.substr(0, 220), sb.substr(0, 220)])

func _report(ok: bool, msg: String) -> void:
	print("PROBE|%s（%s）" % ["端到端续档 ✅ 全过" if ok else "端到端续档 ❌ 失败", msg])
	print("PROBE|END")
	get_tree().quit(0 if ok else 1)
