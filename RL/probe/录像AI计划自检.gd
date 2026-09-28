extends Node
## 【2026-09-27 一次性探针】录像回放 · **敌方 AI 计划**那一条路（与 `录像回放自检.gd` 分工不同：
## 那个走"自由部署双控"（敌方也由本端点），只覆盖玩家指令流水；这个走**生产 AI**：
## 敌方回合由 AI 搜索出计划 → 计划整份进录像 → 回放时照计划重演）。
##
## 验什么：
##   ① 敌方那一段的流水 = **AI 计划**（`type == "plan"`），且计划里的每一招都是纯数据（JSON 能存能读）
##   ② 一整局（我走一步 → 结束回合 → AI 走完 → 回到我方）会被切成 ≥3 段，段段有快照
##   ③ 回放这 3 段：终局指纹与录制终局**逐位一致**（含 AI 那一回合的走位/伤害全部复现）
##
## 用法：godot --headless --path . --scene res://RL/probe/录像AI计划自检.tscn
## 退出码 0 = 全过。

const MainScene := preload("res://scenes/Main.tscn")

const P_CELLS: Array[Vector2i] = [Vector2i(1, 4), Vector2i(3, 4), Vector2i(1, 5)]
const E_CELLS: Array[Vector2i] = [Vector2i(1, 2), Vector2i(3, 2), Vector2i(1, 1)]
const P_DECK: Array = ["hero_13", "hero_12", "hero_23"]
const E_DECK: Array = ["hero_06", "hero_17", "hero_26"]

var _fail := 0

func _ready() -> void:
	_run.call_deferred()

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
	print("PROBE|%s %s" % ["PASS" if cond else "FAIL", msg])

func _run() -> void:
	Engine.time_scale = 1.0
	# 清干净：先把上一份同探针留下的录像删掉（用时间戳区分，这里只清"本探针自己的"）
	GameState.replay_id = ""
	GameState.ladder_mode = ""
	GameState.dual_control = false       # ★ 与另一个探针的差别：敌方回合交给**生产 AI**
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.is_online = false
	GameState.ai_difficulty = 1          # 普通档（BEAM 100）：探针要的是"AI 计划进了录像"，不是最强棋力
	GameState.match_over = false
	GameState.clear_placement()
	for i in P_CELLS.size():
		GameState.player_placement[P_CELLS[i]] = P_DECK[i]
	for i in E_CELLS.size():
		GameState.enemy_placement[E_CELLS[i]] = E_DECK[i]
	GameState.player_deck = P_DECK.duplicate()
	GameState.enemy_deck = E_DECK.duplicate()

	var before: int = ReplayStore.list().size()

	# ---------- 第一局：真打一小段 + 结算落盘 ----------
	var b: Battle = MainScene.instantiate() as Battle
	add_child(b)
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(b._rec_on, "开局已登记录像（_rec_on=true）")
	await _wait_deploy(b)

	# 我方 3 人各走一步（够近：1,4 → 1,3 之类；走不动就原地不动，也算一招）
	var moved := 0
	for u in b.units:
		if u.faction != DataRegistry.Faction.PLAYER or not u.alive:
			continue
		var to := _step_toward_enemy(b, u)
		if to != Vector2i(-99, -99):
			b.submit_move(b.units.find(u), to)
			moved += 1
			await _wait_idle(b)
			break   # 只走一步：这一探针要的是"AI 那一回合"，不是打满一局
	print("PROBE|我方尝试移动 %d 人；录得帧数=%d 招数=%d" % [
		moved, b._rec.frame_count(), _steps_of(b._rec)])

	# 交给敌方：生产 AI 搜索 + 逐招回放（这一步会把整份计划记进录像）
	var turn_t0 := Time.get_ticks_msec()
	b.submit_end_turn()
	await _wait_side(b, GameState.SIDE_ENEMY)
	# 等 AI 那一回合跑完、回到我方（AI 搜索最慢，给足 120 秒）
	var tw := Time.get_ticks_msec()
	while GameState.active_side != GameState.SIDE_PLAYER and Time.get_ticks_msec() - tw < 120000:
		if GameState.match_over:
			break
		await get_tree().process_frame
	await _wait_idle(b)
	print("PROBE|AI 回合结束：active_side=%d state=%d 场上=%d 单位" % [GameState.active_side, b.state, b.units.size()])

	# 记录"录制侧"的终局指纹
	var fp_rec: String = _fingerprint(b)
	print("PROBE|录制侧终局指纹：%s" % fp_rec)

	# 结算：走真实那条路（`_emit_match_result` ⇒ `_rec_finish` ⇒ ReplayStore.save）
	var rank_before: Array = ReplayStore.list()
	b._emit_match_result(GameState.SIDE_PLAYER)
	await get_tree().process_frame
	var lst: Array = ReplayStore.list()
	_ok(lst.size() == before + 1, "结算后录像落盘（索引 %d → %d 条）" % [before, lst.size()])
	if lst.is_empty():
		_report()
		return
	var rec: Dictionary = lst[0]
	var id := String(rec.get("id", ""))
	print("PROBE|录像索引：id=%s 模式=%s 胜负=%s 段数=%d 招数=%d 时长=%.1fs" % [
		id, String(rec.get("mode", "?")), str(rec.get("win", false)), int(rec.get("frames", 0)),
		int(rec.get("steps", 0)), float(rec.get("dur", 0.0))])
	print("PROBE|录像行文案：%s" % String(rec.get("mode", "")) + " / " + str(rec.get("player", [])))
	var data: Dictionary = ReplayStore.load_replay(id)
	_ok(not data.is_empty(), "录像文件能读回来")
	if data.is_empty():
		_report()
		return
	var frames: Array = data.get("frames", [])
	_ok(frames.size() >= 2, "录像至少含 2 段（双方各一段），实得 %d" % frames.size())
	var all_snap := true
	var all_clip := true
	var steps_total := 0
	for f in frames:
		var fd: Dictionary = f
		if (fd.get("snap", {}) as Dictionary).is_empty():
			all_snap = false
		if float(fd.get("clip", -1.0)) < 0.0:
			all_clip = false
		steps_total += (fd.get("steps", []) as Array).size()
	_ok(all_snap, "每一段都带局面快照")
	_ok(all_clip, "每一段都带时长（clip ≥ 0）")
	_ok(steps_total >= 1, "招式流水非空（共 %d 招）" % steps_total)
	_ok(not b._rec_on and b._rec == null, "落盘后录制器已收尾")
	# 【2026-09-27 用户要求「不需要把思考时间复制进回放」】段的时长之和必须明显小于这一回合的墙钟
	var clip_sum := 0.0
	for f in frames:
		clip_sum += float((f as Dictionary).get("clip", 0.0))
	var wall := float(Time.get_ticks_msec() - turn_t0) / 1000.0
	print("PROBE|时长对账：段时长合计 %.1fs · 本回合墙钟 %.1fs · 录像总时长 %.1fs" % [
		clip_sum, wall, float((data.get("meta", {}) as Dictionary).get("dur", 0.0))])
	_ok(clip_sum < wall * 0.7, "录下的时长已扣掉 AI 思考（%.1fs < 墙钟 %.1fs）" % [clip_sum, wall])
	var plan_frames := 0
	var plan_steps := 0
	for f in frames:
		for st in ((f as Dictionary).get("steps", []) as Array):
			if String((st as Dictionary).get("type", "")) == "plan":
				plan_steps += 1
				plan_frames += 1
				var pl: Array = (st as Dictionary).get("plan", [])
				print("PROBE|AI 计划段：第 %d 段 · 计划 %d 步 · 首步 idx=%d action=%s" % [
					plan_frames, pl.size(), int((pl[0] as Dictionary).get("idx", -1)),
					str((pl[0] as Dictionary).get("action", {}))])
	print("PROBE|带 AI 计划的段数 = %d / %d（计划步共 %d）" % [plan_frames, frames.size(), plan_steps])
	_ok(frames.size() >= 3, "一整局被切成 ≥3 段（实得 %d）" % frames.size())
	_ok(plan_frames >= 1, "敌方那一段的流水是 AI 计划（type=plan）")
	b.queue_free()
	await get_tree().process_frame

	# ---------- 第二局：走回放路径，逐段重演 ----------
	GameState.replay_id = id
	var r: Battle = MainScene.instantiate() as Battle
	add_child(r)
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(r._replay_mode, "第二局进入回放模式（_replay_mode=true）")
	_ok(r.replay_frame_count() == frames.size(), "回放段数 = 录像段数（%d）" % frames.size())
	_ok(r.units.size() > 0, "回放第 0 段已重建局面（场上 %d 个单位）" % r.units.size())

	# 走到最后一段：走**产品自己的那条路**（`replay_seek_frame` 登记请求 → `_replay_loop()` 快进重演）。
	# 探针只观察，不自己推进（那样会和循环交叉推进）；"这一段重演了几招"用 `_replay_step` 的增量核对。
	r.replay_set_speed(4.0)
	r.replay_set_paused(true)
	r._obs_target = 1   # 【探针观测】打开"重演招数"累计计数（见 `Battle._obs_n` 的说明）
	# ① 先"上回合"回到开局（倒回走 `_replay_rewind`：从第 0 段重建 + 快进到第 0 段开头）
	await _do_seek(r, 0)
	# ② 再"下回合"直奔末段（这一趟 = 把第 0 段剩下的招重演完 + 换段）
	var t0 := Time.get_ticks_msec()
	await _do_seek(r, frames.size() - 1)
	await _wait_loop_end(r)
	var dt := Time.get_ticks_msec() - t0
	# `_obs_n`（`_apply_replay_step` 调用总次数，跳段会重置步骤指针 ⇒ 用累计量才不会被清零）
	var played: int = r._obs_n
	r.replay_set_paused(true)
	var fp_play: String = _fingerprint(r)
	# 参照物取**录像文件里的终局快照**（而不是录制侧内存里的局面）：这样"落盘 → 读回 → 重演"整条链
	# 都要对上，任何一个环节丢字段/串类型都会当场露出来。
	print("PROBE|回放侧终局指纹：%s（重演 %d 招 · 墙钟 %d ms）" % [fp_play, played, dt])
	# 参照物 = 录制侧打到最后那一刻的局面指纹（`fp_rec`，在这之前就取好了）。
	# 录像最后一段的快照是"那一方回合**开始**时"的局面（不是终局）⇒ 不能拿它当参照。
	_ok(fp_play == fp_rec, "回放终局与录制终局逐位一致")
	_ok(played >= 2, "回放期间确实在重演招式（累计重演 %d 招 · 录像共 %d 招）" % [played, steps_total])

	# ---------- 控制接口 ----------
	r.replay_set_speed(4.0)
	_ok(absf(Engine.time_scale - 4.0) < 0.01, "倍速 4× 生效（time_scale=%.1f）" % Engine.time_scale)
	r.replay_set_speed(1.0)
	r.replay_set_paused(true)
	_ok(r._replay_paused, "暂停标志生效")
	r.replay_set_paused(false)
	_ok(not r._replay_paused, "继续播放生效")
	await _do_seek(r, -5)
	_ok(r._replay_frame == 0 and r._replay_seek_done == 0, "「上回合」越界钳到第 0 段（实得 %d）" % r._replay_frame)
	await _do_seek(r, 999)
	_ok(r._replay_frame == frames.size() - 1, "「下回合」越界钳到最后一段（实得 %d / %d）" % [r._replay_frame, frames.size() - 1])
	print("PROBE|读数：%s" % _panel_text(r))

	_report()
	r.queue_free()
	# 清掉本次探针产生的录像（别把用户的录像列表弄脏）
	ReplayStore.remove(id)
	await get_tree().process_frame
	GameState.replay_id = ""
	print("PROBE|已清理本次探针的录像：%s" % id)
	get_tree().quit(0 if _fail == 0 else 1)

func _report() -> void:
	print("FINAL " + ("PASS" if _fail == 0 else "FAIL(%d)" % _fail))

# ---- 工具 ----

## 等部署结束、并等到**本端可操作**（自由部署路径 `_place_units → _start_match → _begin_side`，
## 提交移动必须发生在 `state == PLAYER_INPUT` 之后，否则会被状态门拦掉）。
## 若本局先手是敌方（双控 ⇒ 也要本端点结束），先替敌方结束回合再等自己。
func _wait_deploy(b) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000:
		if b.state == Battle.State.PLAYER_INPUT:
			return
		if b.state == Battle.State.ENEMY_TURN or (b.state == Battle.State.ANIMATING and GameState.active_side == GameState.SIDE_ENEMY):
			b.submit_end_turn()   # 双控：敌方回合也由本端结束，把它让给我方
			await _wait_idle(b)
			continue
		await get_tree().process_frame
	print("PROBE|（提示）等本端可操作超时：state=%d round=%d" % [b.state, GameState.round_number])

## 等"这一招演完"（行动方回到可提交状态，或换边）
func _wait_idle(b) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 6000:
		if b.state == Battle.State.PLAYER_INPUT or b.state == Battle.State.ENEMY_TURN:
			return
		await get_tree().process_frame

func _wait_side(b, side: int) -> void:
	var t0 := Time.get_ticks_msec()
	while GameState.active_side != side and Time.get_ticks_msec() - t0 < 15000:
		await get_tree().process_frame
	await _wait_idle(b)

## 等主循环跑到"末段演完收工"（跳段请求一登记就唤醒它）
func _wait_loop_end(r) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 40000:
		if not r._replay_loop_running and not r._replay_seeking:
			return
		await get_tree().process_frame
	print("PROBE|（提示）等回放跑完超时：frame=%d/%d seeking=%s" % [r._replay_frame, r.replay_frame_count(), str(r._replay_seeking)])

## 发起一次跳段并等它落地：以 `_replay_seek_seq`（已处理完的跳段次数）为准 ——
## 跳段整趟在**同一帧内**跑完，外部看不到 `_replay_seeking` 的中间态，只能靠这个序号确认。
func _do_seek(r, i: int) -> void:
	r.replay_set_paused(true)
	var seq: int = r._replay_seek_seq
	r.replay_seek_frame(i)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000:
		if r._replay_seek_seq > seq:
			return
		await get_tree().process_frame
	print("PROBE|（提示）跳段超时：请求 %d 实得 %d" % [i, r._replay_frame])

## 局面指纹：单位（阵营/英雄/格/血/攻/状态数）+ 棋盘实体（炸弹/墓碑/道具/障碍）+ 回合与行动方。
## 排序后拼接 ⇒ 与单位数组顺序无关，只反映"局面本身"。
func _fingerprint(b) -> String:
	var rows: Array = []
	for u in b.units:
		if u == null or not is_instance_valid(u) or not u.alive:
			continue
		rows.append("%d/%s@%d,%d/h%d/a%d/m%d" % [
			u.faction, u.hero_id, u.cell.x, u.cell.y, u.hp, u.effective_atk(), u.effective_move()])
	rows.sort()
	var terrain := "b%d/g%d/i%d/o%d" % [b.bombs.size(), b.graves.size(), b.buff_items.size(), b.obstacles.size()]
	var dead := "pd%d/ed%d/pr%d/er%d" % [b.player_dead, b.enemy_dead, b.player_roster.size(), b.enemy_roster.size()]
	return "%s|%s|%s|r%d/s%d" % [";".join(rows), terrain, dead, GameState.round_number, GameState.active_side]

func _steps_of(rec) -> int:
	var n := 0
	if rec == null:
		return 0
	for f in rec.frames:
		n += (f["steps"] as Array).size()
	return n

func _steps_of_frame(f) -> int:
	return (f.get("steps", []) as Array).size()

func _panel_text(r) -> String:
	if r._replay_panel == null or not is_instance_valid(r._replay_panel):
		return "(无控制条)"
	var out: Array = []
	for c in r._replay_panel.get_children():
		for g in c.get_children():
			for n in g.get_children():
				if n is Button:
					out.append((n as Button).text)
				elif n is Label:
					out.append((n as Label).text)
	return " / ".join(out)

## 朝敌方最近单位走一步（挑一个可达且更近的格；找不到就返回哨兵）
func _step_toward_enemy(b, u) -> Vector2i:
	var cells: Dictionary = b._move_reachable(u)
	var best := Vector2i(-99, -99)
	var best_d := 999
	var targets: Array = []
	for e in b.units:
		if e.alive and e.faction != u.faction:
			targets.append(e.cell)
	for c in cells.keys():
		for tc in targets:
			var d: int = b.grid.distance(c, tc)
			if d < best_d and c != u.cell:
				best_d = d
				best = c
	return best
