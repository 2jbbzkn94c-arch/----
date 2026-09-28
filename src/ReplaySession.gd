extends RefCounted
## 录像的"录制 / 回放"数据侧（与 `autoload/ReplayStore.gd` 的读写分开：那边只管文件，这边只管一局的数据形态）。
##
## 【2026-09-27 用户要求】单机对局自动录像 + 可回放（暂停 · 上下回合 · 倍速）。
##
## 一份录像的结构（`ReplayStore` 原样 JSON 落盘）：
##   meta   = { ts, mode, diff, player_deck, enemy_deck, first_side, rounds, win, dur, frames, steps, ver }
##   frames = [ { side, snap, steps, clip }, ... ]   一段 = 一方的半回合
##     · snap  = `Battle._snap_take(side)` 的局面快照（含 rng 状态 ⇒ 重演确定性）
##     · steps = 这一方实际执行过的招式流水（玩家指令 / 敌方每一招，含中途替补落位）
##     · clip  = 这一段的时长（秒）：从本条开始到**下一条开始**为止 ⇒ 回放按它停一拍。
##               ⚠️ **不含思考时间**：AI 搜索耗时由 `note_step(step, think_ms)` 扣掉（用户 2026-09-27 要求）
##
## 为什么不是"每帧存图"：一局 10 回合的录像按这个形态约 100~300 KB，且重演得到的是**真局面**
## （能看卡面/属性、能吃动画演出），不是一张张截图。
##
## 依赖方向：本文件零依赖（Battle 调它，它不反向调 Battle）。

const VER := 1

var meta: Dictionary = {}
var frames: Array = []
var _step_t := 0.0      # 上一招的时刻（算单招时长用）
var _t_first := -1.0    # 整局**第一次开段**的时刻（毫秒）：算总时长用（不含思考）
var _clip_sum := 0.0    # 各段 `clip` 之和（秒）= 回放里真正会播的时长；`meta.dur` 就用它

func begin(m: Dictionary) -> void:
	meta = m.duplicate(true)
	frames = []
	_clip_sum = 0.0
	_step_t = float(Time.get_ticks_msec())
	_t_first = _step_t

## 【2026-09-28 用户报「天梯中途退出重进后，录像从重进那里开始」】把"已经录下的那半截"接回来
## （天梯中局存档里带着 `{meta, frames}`，见 `Battle._rec_pack()` / `_rec_resume()`）。
## 口径：meta / frames 原样接上；时间指针全部归到"现在"—— 退出到重进之间的离线时间
##      既不算进 `clip`（那一段的时长只从重进那一刻起算），也不算进 `meta.think`。
## ⚠️ 接回来时最后一段的 `clip` 还是 0（段是"下一次开段"时才结算的）⇒ 重算 `_clip_sum` 与存档值一致，
##   不会把旧 clip 重复累加。
func resume(data: Dictionary) -> void:
	meta = (data.get("meta", {}) as Dictionary).duplicate(true)
	frames = (data.get("frames", []) as Array).duplicate(true)
	_clip_sum = 0.0
	for f in frames:
		_clip_sum += float((f as Dictionary).get("clip", 0.0))
	_step_t = float(Time.get_ticks_msec())
	_t_first = _step_t

## 开一段（半回合）：side = 即将行动的一方（GameState.SIDE_PLAYER / SIDE_ENEMY）；snap = 那一刻的快照。
## `clip` = "上一次有人出手 → 这一段开始"（回放按它停一拍）。
##   ⚠️ 段内**第一次出手之前**那段等待（玩家的思考、AI 的搜索、回合开始的演出）**不算进 clip**：
##   这正是"回放不要复现思考时间"的落点（用户 2026-09-27 要求）——否则 AI 想 40 秒，回放也得干等 40 秒。
func begin_frame(side: int, snap: Dictionary) -> void:
	var now := float(Time.get_ticks_msec())
	if not frames.is_empty():
		var clip := maxf((now - _step_t) / 1000.0, 0.0)
		frames[frames.size() - 1]["clip"] = clip
		_clip_sum += clip
	_step_t = now
	frames.append({ "side": side, "snap": snap, "steps": [], "clip": 0.0 })

## 记一招（玩家指令 / 敌方的一步 / 替补落位）。step 只放纯数据（JSON 能存的东西）。
## `skip_before` = "这一招以前的纯思考/等待"结束的时刻（毫秒绝对时钟，0 = 没有）：
##   本段第一次出手会带它（AI 搜索开始的那一刻）⇒ 这一段记成"从**出手前那一刻**到下一次开段"，
##   于是**思考时间既进不了 clip、也进不了总时长**（用户 2026-09-27：「不需要把思考时间复制进去」）。
func note_step(step: Dictionary, skip_before: int = 0) -> void:
	if frames.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	if (frames[frames.size() - 1]["steps"] as Array).is_empty() and skip_before > 0:
		_step_t = float(skip_before)   # 本段时长从"出手前那一刻"起算 ⇒ 思考时间进不了 clip
	_step_t = now
	frames[frames.size() - 1]["steps"].append(step)

func has_frames() -> bool:
	return frames.size() > 0

func frame_count() -> int:
	return frames.size()

## 段的行动方。`-1` = **部署画面**（录像第 0 段，`Battle._rec_note_deploy()` 存的那一份快照）。
func side_of(i: int) -> int:
	if i < 0 or i >= frames.size():
		return GameState.SIDE_PLAYER
	return int((frames[i] as Dictionary).get("side", GameState.SIDE_PLAYER))

## 收尾：win = 本端是否获胜。返回可直接落盘的 {meta, frames}。
## 总时长 = 整局墙钟 − 累计思考/等待（`_think_total`）⇒ 与各段 `clip` 之和自洽。
func end(win: bool) -> Dictionary:
	if not frames.is_empty():
		var now := float(Time.get_ticks_msec())
		var clip := maxf((now - _step_t) / 1000.0, 0.0)
		frames[frames.size() - 1]["clip"] = clip
		_clip_sum += clip
	meta["win"] = win
	meta["ver"] = VER
	meta["frames"] = frames.size()
	meta["steps"] = _count_steps()
	# 总时长 = 各段 clip 之和（**不含**任何"段内第一次出手之前"的等待：玩家思考 / AI 搜索 / 回合演出）
	meta["dur"] = _clip_sum
	meta["think"] = maxf((float(Time.get_ticks_msec()) - _t_first) / 1000.0 - _clip_sum, 0.0)
	return { "meta": meta.duplicate(true), "frames": frames.duplicate(true) }

func _count_steps() -> int:
	var n := 0
	for f in frames:
		n += (f["steps"] as Array).size()
	return n

## 【2026-09-28 用户报「录像列表里不显示对方卡组」】索引里的"某一方阵容"兜底：
##   敌方走**配方/队伍池**时 `GameState.enemy_deck` 全程是空的（配方是**部署时**才从池子里挑人，
##   不预先给整副卡组）⇒ 录像索引里 `enemy` 就是空数组、列表那一列空着 —— 可人**真的上过场**。
##   这里把该方"这一局实际用过的人"捞出来，按**可靠性从高到低**几个来源合并：
##   ① 各段快照里的 `*_pool` / `*_deck`（该方本局的卡组/池子，最完整）；
##   ② 各段快照里**出过场的单位**（`vars.hero_id`，按首次出现顺序）与 `*_deployed`、`*_roster`（替补席）。
##   ⚠️ **扫的是全部段、不是只看第 0 段**（用户 2026-09-28 报「对方只有 3 个人」：只看第 0 段只会拿到
##   首发 3 人，中途上过的替补就漏了）。仍然凑不满 8 个也如实显示 —— 那就是这一局真实上过的人。
## 纯数据函数（不碰 Battle）：录像落盘时补一次，主菜单遇到老录像的空字段时也用它兜底。
static func deck_from_data(data: Dictionary, side: int) -> Array:
	var frames: Array = data.get("frames", [])
	if frames.is_empty():
		return []
	var want := DataRegistry.Faction.PLAYER if side == GameState.SIDE_PLAYER else DataRegistry.Faction.ENEMY
	var out: Array = []
	var seen := {}
	var add := func(hid: String) -> void:
		if hid == "" or seen.has(hid) or out.size() >= 8:
			return
		seen[hid] = true
		out.append(hid)
	# ① 池子/卡组（只要有一段的快照里有，就说明该方本局的名单是这个）
	for f in frames:
		var s: Dictionary = (f as Dictionary).get("snap", {})
		for key in ["player_pool", "enemy_pool", "player_deck", "enemy_deck"]:
			var is_mine := String(key).begins_with("player")
			if is_mine != (side == GameState.SIDE_PLAYER):
				continue
			for h in (s.get(key, []) as Array):
				add.call(String(h))
	if out.size() >= 8:
		return out.slice(0, 8)
	# ② 实际出过场的人（场上单位 + 已上阵 + 替补席）
	for f in frames:
		var s2: Dictionary = (f as Dictionary).get("snap", {})
		for u in (s2.get("units", []) as Array):
			var v: Dictionary = (u as Dictionary).get("vars", {})
			if int(v.get("faction", -1)) != want:
				continue
			add.call(String(v.get("hero_id", "")))
		for key2 in ["deployed", "roster"]:
			var k := ("player_" if side == GameState.SIDE_PLAYER else "enemy_") + String(key2)
			for h2 in (s2.get(k, []) as Array):
				add.call(String(h2))
	return out.slice(0, 8)
