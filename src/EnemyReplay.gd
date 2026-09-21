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
		if GameState.match_over:
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
		var idx: int = step["idx"]
		if idx < 0 or idx >= refs.size():
			continue
		var raw_u: Variant = refs[idx]
		if raw_u == null or not is_instance_valid(raw_u):
			continue
		if not (raw_u is Unit):
			continue
		var u: Unit = raw_u as Unit
		if u == null or not u.alive:
			continue
		# 亮起"正在行动"的红橙脉冲描边：多名敌人连续出手时一眼看出轮到谁在动
		u.set_acting_ring(true)
		# 亮边后先停一拍再出手：让玩家先定位到这名英雄，再接它的动作
		await _gap(TELL_GAP if first else HERO_GAP)
		first = false
		if my_session != battle._session_id or not battle.is_inside_tree():
			if is_instance_valid(u):
				u.set_acting_ring(false)
			return   # 已重开/场景已释放：安全退出
		var a: Dictionary = step["action"]
		# ⚠️ 每一处 await 之后都必须**重新验一次**单位引用：这一拍里单位可能已经被打死并走完
		# 死亡淡出（`Battle._on_unit_died` 里 `u.call_deferred("queue_free")`，淡出 0.3s）。
		# 踩炸弹离场、被反击、被强制位移都会在这期间发生；把"已释放的对象"递给 Battle 会直接崩：
		#   Invalid type in function '_do_attack' ... argument 1 (previously freed)
		# （2026-09-15 玩家实战崩在此处：新引擎会算出"踩炸弹换人头"这类走法，命中率明显变高。）
		if not _unit_ok(u):
			continue   # 本步作废：跳过这名单位剩下的动作，继续回放下一条
		# 【2026-09-15 A+B】这一步"想打但没打成"时要能就地补一招 —— 先记下它本来想做什么：
		#   wanted = 计划里带了一次攻击（打人 atk>=0 或 打障碍 atk_obs），acted = 这一击真的打出去了。
		# 走位类步骤（计划里本来就没有攻击）不触发补算，避免每个走位步都白跑一次搜索。
		var wanted: bool = (a.has("atk") and int(a["atk"]) >= 0) or a.has("atk_obs")
		var acted := false
		if a.has("move") and a["move"] != null:
			battle._do_move(u, a["move"], true)
			await _wait_action_done()   # 等待移动动画真正播完（与玩家侧节奏一致）
		if a.has("atk_obs"):
			await _gap(STEP_GAP)   # 移动后顿一拍再敲障碍，避免两段动作粘成一段
			if not _unit_ok(u):
				continue
			battle._do_attack_obstacle(u, a["atk_obs"])
			acted = true
			await _wait_action_done()
		if a.has("atk") and int(a["atk"]) >= 0:
			var t_idx := int(a["atk"])
			if t_idx >= 0 and t_idx < refs.size() and _unit_ok(refs[t_idx]):
				var t: Unit = refs[t_idx]
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
					battle._do_attack_obstacle(u, alt["atk_obs"])
					await _wait_action_done()
				var alt_atk := int(alt.get("atk", -1))
				if alt_atk >= 0 and alt_atk < refs.size() and _unit_ok(refs[alt_atk]) and _unit_ok(u):
					var t2: Unit = refs[alt_atk]
					if t2.faction != DataRegistry.Faction.ENEMY and battle._in_attack_range(u, t2):
						await _gap(STEP_GAP)
						if _unit_ok(u) and _unit_ok(t2) and battle._in_attack_range(u, t2):
							battle._do_attack(u, t2, true)
							await _wait_action_done()
		# 本英雄行动结束：熄灭行动描边（下一名英雄出手前会重新亮起，交接不拖影）
		if is_instance_valid(u):
			u.set_acting_ring(false)
	# 全部行动结束：留一拍再进回合末结算（避免最后一招与回合结束演出首尾相连）
	if my_session != battle._session_id or not battle.is_inside_tree():
		return
	await _gap(STEP_GAP)

## 暂停中不推进任何一步（单机暂停用；联机不暂停，故几乎是空转）
func wait_unpaused() -> void:
	while battle.is_inside_tree() and battle.get_tree().paused:
		await battle.get_tree().process_frame

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
