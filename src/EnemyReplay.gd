class_name EnemyReplay
extends RefCounted
## 敌方 AI 计划的"演出回放器"：主线程逐招执行 Battle 的动作函数并等动画播完。
##
## 为什么要独立成文件：这段是**流程 + 演出 + 等待兜底**，跟"AI 怎么决策"（BattleAI）和
## "这一手在规则上能不能做"（Battle 的 _do_move/_do_attack）都是不同关注点。
## 以前它跟回合流程、快照打包一起挤在 Battle.gd 里（约 170 行）。
##
## 依赖方向：EnemyReplay → Battle（动态调用其动作函数/等待状态）。battle 故意未定型，
## 以便调用 Battle 的私有方法（与 HeroBase 同一约定）。
##
## 节奏常量也归这里：一人一停、一招一停，避免多名敌人连招连成一片看不清谁在动。
const HERO_GAP := 0.7    # 相邻两名不同英雄的行动之间
const STEP_GAP := 0.25   # 同一名英雄"移动→攻击"之间
const TELL_GAP := 0.3    # 回放第一步：亮起行动描边后、出手前的起手停顿

var battle = null   # 未定型：需要动态调用 Battle 的私有方法/成员

func _init(battle_) -> void:
	battle = battle_

# ---- 对外 ----

## 回放整份计划。注意用**下标 while** 而不是 for：敌方回合中途落位的替补会把补算的一步
## 追加到 plan 尾部（Battle._plan_enemy_late_sub），for 迭代期间追加不可靠。
func run(plan: Array, refs: Array, my_session: int) -> void:
	var first := true          # 本回合第一招（起手停顿更短，回合切换本身已有停顿）
	var si := 0
	while si < plan.size():
		var step: Dictionary = plan[si]
		si += 1
		battle._replay_plan_pos = si   # 回放进度（"已经演到第几步"）——见 Battle 里那个成员的说明
		# 【2026-09-28】上一招（`plan[si-2]`）此刻已演完、局面已定型 ⇒ 补上"它之后"的局面指纹
		#   （录制侧用；回放里 `_rec_on` 为 false，什么都不做）。见 `Battle._rec_fp()` 的说明。
		if battle._rec_on and si >= 2:
			var prev: Dictionary = plan[si - 2]
			if not prev.has("fp"):
				prev["fp"] = battle._rec_step_fp()
		if GameState.match_over or battle._replay_decided():
			break
		if my_session != battle._session_id:
			return   # 已重开：安全退出，避免访问已释放单位
		if not is_instance_valid(battle):
			return   # Battle 已被释放：协程恢复后立即退出，不再触碰任何引擎调用
		if not battle.is_inside_tree():
			return   # 已脱离场景树：安全退出（**不能写成 battle.get_tree() == null**：
			# 节点被移出场景树后调 get_tree()，引擎会报 Parameter "data.tree" is null）
		await _wait_sub_done()   # 若在替补流程则暂停，等玩家选好并落位
		await wait_unpaused()    # 暂停中：不推进敌方下一步（恢复后继续）
		# 【2026-09-25 修·用户实机「敌方回合，敌方死了三人后，敌方执行的动画还在动」】
		#   阵亡的**计数与判负**挂在 `Unit.died` 上，比 `alive = false` 晚 0.3s（淡出）⇒ 上一步里玩家反击
		#   把第 3 个敌人反杀时，`Battle._finish_attack()` 那次 `_check_win()` 看到的还是"才死 2 个"、于是
		#   放行 ⇒ 下一名敌人照样亮描边/走位/出手（用户看到的就是这一整步）。
		#   这里先把死亡结算排空（≤0.3s，与回合末 `Battle._drain_pending_deaths()` 同一把尺）再判一次
		#   ⇒ 绝不在"已经判负（或判胜）"之后再走一步。**纯节奏守卫**：不改伤害、不改判定、不改死亡时序。
		#   【2026-09-29】`battle._replay_decided()`：回放里 `match_over` 恒假（回放不判胜负）⇒ 这条守卫
		#   在录像里原来**从来没生效**，用户看到"人都死够了、另一边还在动"。判据与实战判负线同一把尺。
		if is_instance_valid(battle) and battle.is_inside_tree():
			await battle._drain_pending_deaths()
		if GameState.match_over or battle._replay_decided() or my_session != battle._session_id:
			break
		var idx: int = step["idx"]
		var u: Unit = _resolve_unit(step.get("who", null), refs, idx)
		if u == null or not u.alive:
			continue   # 这一步指向的单位找不到 / 已阵亡：跳过（老录像的 idx 越界同理）
		# 亮起"正在行动"的红橙脉冲描边：多名敌人连续出手时一眼看出轮到谁在动
		u.set_acting_ring(true)
		# 亮边后先停一拍再出手：让玩家先定位到这名英雄，再接它的动作
		await _gap(TELL_GAP if first else HERO_GAP)
		first = false
		if my_session != battle._session_id or not battle.is_inside_tree():
			if is_instance_valid(u):
				u.set_acting_ring(false)
			return   # 已重开/场景已释放：安全退出
		await _park_with_ring(u)   # 【2026-09-30 凌晨】停顿这一拍里按了暂停 ⇒ 这一招先别出手
		await _do_step_action(u, step, refs, my_session)
		# 本英雄行动结束：熄灭行动描边（下一名英雄出手前会重新亮起，交接不拖影）
		if is_instance_valid(u):
			u.set_acting_ring(false)
	await _tail_after_plan(plan, my_session)

## 【2026-09-28·斩杀撤人】把"计划跑完之后才追加进来的步骤"接着演完。
## 为什么需要它：敌方回合**中途**落位的替补会把补算的那一手追加到 plan 尾部
##   （`Battle._plan_enemy_late_sub()`，含"斩杀撤人"撤下后换上来的替补）。
##   而 `run()` 的 while 在那一刻**已经正常结束**（读到的尾部就是当时那一步），
##   撤下/落位/追加都发生在它返回之后 ⇒ 追加的那一步没人演 ⇒ 替补"站着不出手"。
##   ⇒ Battle 在"撤下 + 落位"完成后再调本函数，从 `from_idx` 接着把新追加的步骤演完。
## 与 `run()` 共用同一套逐招实现（`_do_step_action()`）与同一段收尾（`_tail_after_plan()`）。
func run_from(plan: Array, refs: Array, my_session: int, from_idx: int) -> void:
	var si: int = maxi(from_idx, 0)
	while si < plan.size():
		var step: Dictionary = plan[si]
		si += 1
		battle._replay_plan_pos = si
		if battle._rec_on and si >= 2:
			var prev: Dictionary = plan[si - 2]
			if not prev.has("fp"):
				prev["fp"] = battle._rec_step_fp()
		if GameState.match_over or battle._replay_decided():
			break
		if my_session != battle._session_id or not is_instance_valid(battle) or not battle.is_inside_tree():
			return
		await _wait_sub_done()
		await wait_unpaused()
		if is_instance_valid(battle) and battle.is_inside_tree():
			await battle._drain_pending_deaths()
		if GameState.match_over or battle._replay_decided() or my_session != battle._session_id:
			break
		var u: Unit = _resolve_unit(step.get("who", null), refs, int(step["idx"]))
		if u == null or not u.alive:
			continue
		u.set_acting_ring(true)
		await _gap(HERO_GAP)   # 接着演：不算"本回合第一招"，用常规节奏
		if my_session != battle._session_id or not battle.is_inside_tree():
			if is_instance_valid(u):
				u.set_acting_ring(false)
			return
		await _park_with_ring(u)   # 【2026-09-30 凌晨】同上：停顿这一拍里按了暂停 ⇒ 先别出手
		await _do_step_action(u, step, refs, my_session)
		if is_instance_valid(u):
			u.set_acting_ring(false)
	await _tail_after_plan(plan, my_session)

## 把**一步**真正演出来（`run()` 与 `run_from()` 共用）。调用方负责：解析单位、亮/灭描边、节奏停顿。
## ⚠️ 每一处 await 之后都必须**重新验一次**单位引用：这一拍里单位可能已经被打死并走完
##   死亡淡出（`Battle._on_unit_died` 里 `u.call_deferred("queue_free")`，淡出 0.3s）。
##   踩炸弹离场、被反击、被强制位移都会在这期间发生；把"已释放的对象"递给 Battle 会直接崩：
##     Invalid type in function '_do_attack' ... argument 1 (previously freed)
##   （2026-09-15 玩家实战崩在此处：新引擎会算出"踩炸弹换人头"这类走法，命中率明显变高。）
func _do_step_action(u: Unit, step: Dictionary, refs: Array, my_session: int) -> void:
	var a: Dictionary = step["action"]
	if not _unit_ok(u):
		return   # 本步作废：跳过这名单位剩下的动作
	# 【2026-09-15 A+B】这一步"想打但没打成"时要能就地补一招 —— 先记下它本来想做什么：
	#   wanted = 计划里带了一次攻击（打人 atk>=0 或打障碍 atk_obs），acted = 这一击真的打出去了。
	# 走位类步骤（计划里本来就没有攻击）不触发补算，避免每个走位步都白跑一次搜索。
	var wanted: bool = (a.has("atk") and int(a["atk"]) >= 0) or a.has("atk_obs")
	var acted := false
	if a.has("move") and a["move"] != null:
		battle._do_move(u, a["move"], true)
		await _wait_action_done()   # 等待移动动画真正播完（与玩家侧节奏一致）
	if a.has("atk_obs"):
		await _gap(STEP_GAP)   # 移动后顿一拍再敲障碍，避免两段动作粘成一段
		if not _unit_ok(u):
			return
		battle._do_attack_obstacle(u, a["atk_obs"], true)
		acted = true
		await _wait_action_done()
	if a.has("atk") and int(a["atk"]) >= 0:
		# 【2026-09-28】目标也按**稳定身份**解析（录像里带 `tgt` 标签时），老录像退回 `refs[atk]`
		var t: Unit = _resolve_unit(a.get("tgt", null), refs, int(a["atk"]))
		if t != null and _unit_ok(t):
			if t.faction != DataRegistry.Faction.ENEMY and _unit_ok(u):
				# 只允许攻击当前射程内的目标（防御 AI 计划偏差/移动失败导致越界攻击）
				if battle._in_attack_range(u, t):
					await _gap(STEP_GAP)   # 走位与出手之间留一拍，读得出"先走再打"
					# 这一拍里出手方与被打方都可能死掉/被释放（炸弹、反击、位移）→ 出手前再验一次；
					# 射程也重新判一次：这一拍里目标可能被击退到射程外。
					if _unit_ok(u) and _unit_ok(t) and battle._in_attack_range(u, t):
						battle._do_attack(u, t, true)
						acted = true
						await _wait_action_done()   # 等待攻击（含反击）演出完全结束
	# 【2026-09-15 A+B·用户批准】想打却没打成（目标已死 / 被推出射程 / 这一步本来安排的攻击不存在了）
	# → 让 Battle 就地为这个单位**重搜一招**（用真实局面），把这一手补上，而不是让它白站一回合。
	# 为什么会失效：计划是回合开始时按"预测的残局"一次性排好的（预测与真实结算哪怕差一点，
	# 后面针对同一目标的步骤就会落空）。补算在主线程跑一次短搜索（1.2s 预算），结果同样要过合法性检查。
	if wanted and not acted and _unit_ok(u) and not u.attacked_this_turn:
		if my_session != battle._session_id or not battle.is_inside_tree():
			return   # 已重开/场景已释放：不再补算
		await _gap(STEP_GAP)   # 补算前留一拍，别让"原本那一招"和"补的这一招"粘成一段
		var alt: Dictionary = battle._replan_enemy_action(u)
		if not alt.is_empty() and _unit_ok(u) and not u.attacked_this_turn:
			if alt.get("move", null) != null:
				battle._do_move(u, alt["move"], true)
				await _wait_action_done()
			if alt.has("atk_obs") and _unit_ok(u):
				await _gap(STEP_GAP)
				battle._do_attack_obstacle(u, alt["atk_obs"], true)
				await _wait_action_done()
			var alt_atk := int(alt.get("atk", -1))
			if alt_atk >= 0 and alt_atk < refs.size() and _unit_ok(refs[alt_atk]) and _unit_ok(u):
				var t2: Unit = refs[alt_atk]
				if t2.faction != DataRegistry.Faction.ENEMY and battle._in_attack_range(u, t2):
					await _gap(STEP_GAP)
					if _unit_ok(u) and _unit_ok(t2) and battle._in_attack_range(u, t2):
						battle._do_attack(u, t2, true)
						await _wait_action_done()

## 计划全部演完之后收尾（`run()` 与 `run_from()` 共用）：
## 补最后一招的局面指纹 → 留一拍 → 等结束语音（用户口径「AI 在没有结束语音之前，玩家不能行动」）。
func _tail_after_plan(plan: Array, my_session: int) -> void:
	# 全部行动结束：留一拍再进回合末结算（避免最后一招与回合结束演出首尾相连）
	if my_session != battle._session_id or not battle.is_inside_tree():
		return
	# 【2026-09-28】计划里**最后一招**也补上"它之后"的局面指纹（录制侧用）
	if battle._rec_on and plan.size() > 0:
		var last: Dictionary = plan[plan.size() - 1]
		if not last.has("fp") and battle.is_inside_tree():
			last["fp"] = battle._rec_step_fp()
	await _gap(STEP_GAP)
	# 【2026-09-28·用户口径「AI 在没有结束语音之前，玩家不能行动」】兜底：计划里最后一步若是
	#   不带移动/攻击的步骤（没走 `_wait_action_done`），这里再等一次 —— 保证回合末交还控制权前安静。
	await _wait_voice_done()

## 【2026-09-30 凌晨】"亮起描边 → 起手停顿"这一拍里观众按了暂停 ⇒ **这一招先别出手**：
##   把描边熄掉、停在这儿等放行，放行后再亮起来接着演。
##   为什么还要这一道：`_gap()` 用的是 `create_timer(sec, false)`（只跟整棵树 paused，不认回放的暂停标志），
##   所以"闸门"必须在**停顿之后、出手之前**再等一次 —— 否则按暂停的时机只要落在那一拍里
##   （一人 0.7 秒的窗口），观众就会看到"暂停了还多打一名英雄"。
##   ⚠️ 实战 `_replay_mode` 恒 false ⇒ 本函数一次都不等（实机逐位不变）。
func _park_with_ring(u: Unit) -> void:
	if not (battle._replay_mode and battle._replay_paused and battle._replay_seek_to < 0):
		return
	if is_instance_valid(u):
		u.set_acting_ring(false)
	await wait_unpaused()
	if is_instance_valid(u) and u.alive:
		u.set_acting_ring(true)

## 暂停中不推进任何一步。
##   · **单机对局的暂停**（ESC，整棵树 `paused`）：一直是这一条；
##   · 【2026-09-30 凌晨 用户问「回合中的暂停必须等所有英雄行动完才暂停吗」·已修】**录像回放的暂停**
##     （控制条那颗按钮 ⇒ `Battle._replay_paused`）从前**不经过这里** ⇒ 敌方那一段是**一步**（录像里
##     `side=1` 的 steps 只有一条 `plan`，里面装着全体敌人的招）⇒ 按暂停要等**整份计划**演完才停
##     （探针实测：暂停那 5 秒里计划进度 1 → 2 → 3，所有敌人都照打）。
##     现在每个**步骤开头**都等一次 ⇒ **当前这名英雄这一招演完就停住**，与玩家侧"一招一步"同一粒度。
##   · 实战不读这个标志（那边 `_replay_paused` 恒 false）⇒ 实机逐位不变；
##     回放的"快进重演"期间主循环会先把它置 false（见 `Battle._replay_loop()`）⇒ 也不受影响。
##   · ⚠️ 新一轮跳段请求（`_replay_seek_to >= 0`）**当场放行**：否则"暂停中点下回合"会卡在这里 ——
##     主循环正等着这份计划演完才轮到处理那个请求（让计划先收尾，跳段随后照常落地）。
func wait_unpaused() -> void:
	while battle.is_inside_tree() and (battle.get_tree().paused \
			or (battle._replay_mode and battle._replay_paused and battle._replay_seek_to < 0)):
		await battle.get_tree().process_frame

# ---- 单位解析（稳定身份优先）----

## 按"稳定身份"找这一步说的是哪个单位：优先用计划里记的标签（阵营 + 英雄 id + 当时的落点），
## 标签找不到人或老录像没有标签时，才退回 `refs[idx]`。
## 【2026-09-28 修·用户报的"录像里某个单位差一格/死者对不上"】`idx` / `atk` 都是**当时 units 数组的下标**，
##   而回放侧那一刻的数组顺序或内容只要有一点不同（召唤物、替补落位先后…），这一招就会作用到别人身上。
func _resolve_unit(tag, refs: Array, idx: int) -> Unit:
	if tag is Dictionary:
		var by_tag := _find_by_tag(tag as Dictionary)
		if by_tag != null:
			return by_tag
	if idx < 0 or idx >= refs.size():
		return null
	var r = refs[idx]
	if r != null and is_instance_valid(r) and r is Unit:
		return r as Unit
	return null

## 标签（`{fn, hid, cell}`）→ 当前场上的单位。**实体解析在 `Battle._find_unit_by_tag()`**（玩家指令那一路
## 也用它，两处必须同口径）；这里只是个别名，保留旧名给本文件内部调用。
func _find_by_tag(tag: Dictionary) -> Unit:
	return battle._find_unit_by_tag(tag)

# ---- 内部等待原语 ----

# 替补流程期间暂停敌方 AI 执行（轮询直到替补结束）
func _wait_sub_done() -> void:
	if not is_instance_valid(battle):
		return   # Battle 已释放：直接结束轮询
	var my_session: int = battle._session_id
	# 有效性写进循环条件：本函数是跨帧协程，每一帧回到这里时 Battle 都可能已被释放/已脱离场景树
	while is_instance_valid(battle) \
			and (battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB):
		if my_session != battle._session_id:
			return   # 已重开：安全退出
		if not battle.is_inside_tree():
			return   # 已脱离场景树：停止轮询，避免访问 null get_tree()
		await battle.get_tree().process_frame

# 等待敌方单位的一招动画播完（移动/攻击）。信号与超时竞速：
# 正常情况下 Battle._finish_move/_finish_attack 会发射 action_finished，立即返回；
# 若防御路径漏发射（单位被释放、异常提前返回等），3s 超时兜底，避免回放永久挂起。
func _wait_action_done() -> void:
	if not is_instance_valid(battle):
		return   # Battle 已释放：停止等待
	var my_session: int = battle._session_id
	var done := [false]   # 用数组承载：lambda 改元素不触发"重赋值捕获"混淆
	battle.action_finished.connect(func(): done[0] = true, CONNECT_ONE_SHOT)
	if not battle.is_inside_tree():
		return   # 已脱离场景树：直接返回
	var limit: SceneTreeTimer = battle.get_tree().create_timer(3.0, false)
	while not done[0] and not limit.time_left <= 0.0:
		if my_session != battle._session_id:
			return   # 已重开：安全退出
		if not is_instance_valid(battle):
			return   # Battle 已释放：停止等待
		if not battle.is_inside_tree():
			return   # 已脱离场景树：停止轮询
		await battle.get_tree().process_frame
	# 【2026-09-28·用户口径「AI 在没有结束语音之前，玩家不能行动」】演出结束 ≠ 喊完：
	#   先让本步的死亡结算落定（阵亡喊话挂在那条链上），再等英雄声音真正播完 ——
	#   之后才放行下一招，也才轮到回合末把控制权交还玩家。
	if is_instance_valid(battle) and battle.is_inside_tree() and my_session == battle._session_id:
		await battle._drain_pending_deaths()
	await _wait_voice_done()

## 【2026-09-28·用户口径「AI 在没有结束语音之前，玩家不能行动」】等这一步的英雄声音
##   （喊话 / 攻击音 / 技能音）真正播完再放行。行走音不计（见 `AudioManager._note_voice`）。
##   · 轮询 `AudioManager.voice_time_left()`（它已按 `Engine.time_scale` 折算 ⇒ 快进不拖）；
##   · 录像回放（`_replay_mode`）**不等**：那里每一步的节奏另有机制，再叠一层真实音频时长
##     会把倍速拖平；
##   · 6 秒兜底：任何异常下都不会卡住回合。
func _wait_voice_done() -> void:
	if not is_instance_valid(battle) or not battle.is_inside_tree():
		return
	if battle._replay_mode:
		return
	var my_session: int = battle._session_id
	var deadline := Time.get_ticks_msec() + 6000
	while AudioManager.voice_time_left() > 0.02 and Time.get_ticks_msec() < deadline:
		if my_session != battle._session_id or not is_instance_valid(battle) \
				or not battle.is_inside_tree():
			return
		await battle.get_tree().process_frame

# 回放中的节奏停顿（可被重开安全打断；process_always=false 故跟随暂停一起停）
func _gap(sec: float) -> void:
	if sec <= 0.0 or not battle.is_inside_tree():
		return   # 已脱离场景树：不停顿直接返回
	await battle.get_tree().create_timer(sec, false).timeout

## 单位引用是否还能安全递给 Battle —— 回放里**每次 await 之后**都要复检一次：
## 既没被释放（阵亡后 0.3s 淡出结束会 queue_free），也还活着。
## 为什么这层防御必须留在回放器：计划只是"预测"，玩家侧的反击/炸弹/位移会真实改变局面，
## 任何一次 await 都是"局面可能变了"的窗口；漏验一次就是把已释放对象递给 Battle（崩）。
func _unit_ok(x) -> bool:
	if x == null or not is_instance_valid(x):
		return false
	if not (x is Unit):
		return false
	return (x as Unit).alive
