extends Node
## 【2026-09-27 一次性探针】录像回放端到端自检（不改生产代码，只跑真实 Battle 场景）。
##
## 验什么：
##   ① 单机对局会自动录像：打完一局结算时录像落盘（`ReplayStore` 有索引 + 文件能读回来）
##   ② 录像形态合理：帧数 = 双方各回合数、每帧都有快照、招式流水非空
##   ③ 回放保真：另起一局 Battle 走回放路径（`_replay_begin`）逐段重演，**终局指纹与录制时逐位相同**
##   ④ 控制接口：暂停/倍速/上下回合（`replay_set_paused` / `replay_set_speed` / `replay_seek_frame`）可用且不越界
##
## 用法：godot --headless --path . --scene res://RL/probe/录像回放自检.tscn
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
	GameState.dual_control = true        # 敌方回合由本端"操控"⇒ 不跑生产 AI，探针可复现
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.is_online = false
	GameState.ai_difficulty = 1
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
	print("PROBE|我方尝试移动 %d 人；录得帧数=%d 招数=%d" % [
		moved, b._rec.frame_count(), _steps_of(b._rec)])

	# 交给敌方：探针里敌方也是"本端操控"（dual_control）⇒ 直接结束，观察换段
	b.submit_end_turn()
	await _wait_side(b, GameState.SIDE_ENEMY)

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
	b.queue_free()
	await get_tree().process_frame

	# ---------- 第二局：走回放路径，逐段重演 ----------
	GameState.replay_id = id
	var r: Battle = MainScene.instantiate() as Battle
	add_child(r)
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(r._replay_mode, "第二局进入回放模式（_replay_mode=true）")
	# ---------- 回放 ----------
	# 【2026-09-27 用户报「怎么录像功能可以点击下方的按钮」】回放里 HUD 的战场按钮必须全部收起
	var bn_hidden := true
	if r._hud != null and is_instance_valid(r._hud):
		for hb in [r._hud._end_btn, r._hud._restart_btn, r._hud._back_btn, r._hud._pause_btn]:
			if hb != null and is_instance_valid(hb) and (hb as Button).visible:
				bn_hidden = false
	_ok(bn_hidden, "回放里「结束回合/重开/返回选人/暂停」全部隐藏")

	# 【2026-09-27 用户要求「回合切换要提示蓝方/红方」】开局那条横幅
	r.replay_set_paused(true)   # 播放循环是异步起的，先停住才读得稳
	var bn0 := _banner_text(r)
	print("PROBE|回放开局横幅：%s" % bn0)
	_ok(bn0.begins_with("蓝方回合") or bn0.begins_with("红方回合"), "回放开局报出「蓝方/红方回合」横幅")
	var top0 := _top_label(r)
	print("PROBE|顶栏：%s" % top0)
	_ok(top0.find("你的回合") < 0 and top0.find("敌方回合") < 0, "顶栏不出现「你的回合/敌方回合」")
	_ok(top0.find("蓝方回合") >= 0 or top0.find("红方回合") >= 0, "顶栏按「蓝方/红方回合」报当前段")

	# 【2026-09-27 用户要求「录像先提示哪方回合，然后再开始动」】先亮横幅、再演头一招
	# 站位：跳回第 0 段 → 屏上停在第 0 段开头（横幅刚亮）→ 点「继续」→ 头一招应在那一拍之后才开演。
	r._obs_target = 1   # 【探针观测】打开"重演招数"累计计数（见 `Battle._obs_n` 的说明）
	r.replay_set_speed(1.0)
	var obs_before: int = r._obs_n
	await _do_seek(r, 0)   # 回到第 0 段开头（横幅亮起、停住）
	_ok(r._replay_paused, "跳段后停在那一段开头（不自动往下播）")
	# 跳段那一趟自己会重演出一招（快进重演）⇒ 基准取**跳段前**的计数：
	# "跳段落地 + 点继续"到"下一招落地"之间的墙钟，就是那一拍的长度。
	var t_lead := Time.get_ticks_msec()
	r.replay_set_paused(false)   # 点「继续」：头一招必须在"横幅那一拍"之后才开演
	while r._obs_n < obs_before + 2 and Time.get_ticks_msec() - t_lead < 8000:
		await get_tree().process_frame
	var lead_ms: int = Time.get_ticks_msec() - t_lead
	print("PROBE|先提示、再开打：点继续后 %d ms 才演头一招（预置 %d ms）" % [
		lead_ms, int(r.REPLAY_BANNER_LEAD * 1000.0)])
	_ok(lead_ms >= 1900, "头一招在横幅**整条演出播完**之后才开演（实得 %d ms · 预置 %d ms）" % [
		lead_ms, int(r.REPLAY_BANNER_LEAD * 1000.0)])
	# 【用户要求「回合切换要提示蓝方/红方」】换段后**顶栏**跟着换（第 0 段蓝 → 末段红）。
	# ⚠️ 这里只断言顶栏：换段那条横幅是"亮一会儿就淡掉"的瞬时物，跳段那一拍还在跑，读它不稳
	#   （横幅本身已由上面「先提示、再开打」那条断言覆盖：头一招确实排在横幅之后）。
	await _do_seek(r, 0)
	var top_blue := _top_label(r)
	await _do_seek(r, frames.size() - 1)
	var top_red := _top_label(r)
	print("PROBE|换段读数：第 0 段顶栏=%s / 末段顶栏=%s" % [top_blue, top_red])
	_ok(top_blue != top_red, "换段后顶栏换了阵营（蓝方 ↔ 红方）")

	# 跑完剩下的一整趟（跳到末段 → 自动播完）：看终局指纹是否与录制一致
	var t0 := Time.get_ticks_msec()
	await _do_seek(r, frames.size() - 1)
	_ok(r._replay_frame == frames.size() - 1, "「下回合」到末段（实得 %d / %d）" % [r._replay_frame, frames.size() - 1])
	r.replay_set_paused(false)
	await _wait_loop_end(r)
	var dt := Time.get_ticks_msec() - t0
	var played: int = r._obs_n
	r.replay_set_paused(true)
	var fp_play: String = _fingerprint(r)
	print("PROBE|回放侧终局指纹：%s（累计重演 %d 招 · 墙钟 %d ms）" % [fp_play, played, dt])
	_ok(fp_play == fp_rec, "回放终局与录制终局逐位一致")
	_ok(played >= steps_total, "回放期间确实在重演招式（多趟累计 %d 招 · 本局录像共 %d 招）" % [played, steps_total])

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

## 等主循环收工。判据用"循环已停 或 时间指针已越过末段"——
## ⚠️ 快进重演本身是异步的：它可能还没把请求处理完，`_replay_loop_running` 就已经是 false（探针实测的假早退）。
func _wait_loop_end(r) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 40000:
		if r._replay_seeking:
			await get_tree().process_frame
			continue
		if r._replay_frame > r.replay_frame_count() - 1:
			return
		if not r._replay_loop_running and r._replay_step >= _steps_of_frame(r._frames()[r._replay_frame]):
			return
		await get_tree().process_frame
	print("PROBE|（提示）等回放跑完超时：frame=%d/%d step=%d seeking=%s running=%s" % [
		r._replay_frame, r.replay_frame_count(), r._replay_step,
		str(r._replay_seeking), str(r._replay_loop_running)])

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

## 取 HUD 上那条回合横幅的文字。**读 HUD 自己的引用**（`_turn_banner`）而不是按名字找子节点：
## 换段时旧横幅是 `queue_free()`（当帧还没从树上摘掉）＋ 新横幅同帧建出来 ⇒ 按名字找会抓到旧的那条
## （探针实测：末段读到的还是开局那条 / 空串）。
func _banner_text(r) -> String:
	if r._hud == null or not is_instance_valid(r._hud):
		return ""
	var lb = r._hud._turn_banner
	if lb == null or not is_instance_valid(lb):
		return ""
	return (lb as Label).text

## 顶栏那行"第 N 回合 · 蓝方/红方回合"的文字。
func _top_label(r) -> String:
	if r._hud == null or not is_instance_valid(r._hud) or r._hud._round_label == null:
		return ""
	return (r._hud._round_label as Label).text

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
