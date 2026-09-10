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
		if battle.get_tree() == null:
			return
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
		if my_session != battle._session_id or battle.get_tree() == null:
			if is_instance_valid(u):
				u.set_acting_ring(false)
			return   # 已重开/场景已释放：安全退出
		var a: Dictionary = step["action"]
		if a.has("move") and a["move"] != null:
			battle._do_move(u, a["move"], true)
			await _wait_action_done()   # 等待移动动画真正播完（与玩家侧节奏一致）
		if a.has("atk_obs"):
			if is_instance_valid(u):
				await _gap(STEP_GAP)   # 移动后顿一拍再敲障碍，避免两段动作粘成一段
				battle._do_attack_obstacle(u, a["atk_obs"])
				await _wait_action_done()
		if a.has("atk") and int(a["atk"]) >= 0:
			var t_idx := int(a["atk"])
			if t_idx >= 0 and t_idx < refs.size() and is_instance_valid(refs[t_idx]):
				var t: Unit = refs[t_idx]
				if t.alive and t.faction != DataRegistry.Faction.ENEMY and is_instance_valid(u):
					# 只允许攻击当前射程内的目标（防御 AI 计划偏差/移动失败导致越界攻击）
					if battle._in_attack_range(u, t):
						await _gap(STEP_GAP)   # 走位与出手之间留一拍，读得出"先走再打"
						battle._do_attack(u, t, true)
						await _wait_action_done()   # 等待攻击（含反击）演出完全结束
		# 本英雄行动结束：熄灭行动描边（下一名英雄出手前会重新亮起，交接不拖影）
		if is_instance_valid(u):
			u.set_acting_ring(false)
	# 全部行动结束：留一拍再进回合末结算（避免最后一招与回合结束演出首尾相连）
	if my_session != battle._session_id or battle.get_tree() == null:
		return
	await _gap(STEP_GAP)

## 暂停中不推进任何一步（单机暂停用；联机不暂停，故几乎是空转）
func wait_unpaused() -> void:
	while battle.get_tree() != null and battle.get_tree().paused:
		await battle.get_tree().process_frame

# ---- 内部等待原语 ----

# 替补流程期间暂停敌方 AI 执行（轮询直到替补结束）
func _wait_sub_done() -> void:
	var my_session: int = battle._session_id
	while battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB:
		if my_session != battle._session_id:
			return   # 已重开：安全退出
		if not is_instance_valid(battle):
			return   # Battle 已释放：直接结束轮询
		if battle.get_tree() == null:
			return   # 已脱离场景树：停止轮询，避免访问 null get_tree()
		await battle.get_tree().process_frame

# 等待敌方单位的一招动画播完（移动/攻击）。信号与超时竞速：
# 正常情况下 Battle._finish_move/_finish_attack 会发射 action_finished，立即返回；
# 若防御路径漏发射（单位被释放、异常提前返回等），3s 超时兜底，避免回放永久挂起。
func _wait_action_done() -> void:
	var my_session: int = battle._session_id
	var done := [false]   # 用数组承载：lambda 改元素不触发"重赋值捕获"混淆
	battle.action_finished.connect(func(): done[0] = true, CONNECT_ONE_SHOT)
	if battle.get_tree() == null:
		return   # 已脱离场景树：直接返回
	var limit: SceneTreeTimer = battle.get_tree().create_timer(3.0, false)
	while not done[0] and not limit.time_left <= 0.0:
		if my_session != battle._session_id:
			return   # 已重开：安全退出
		if not is_instance_valid(battle):
			return   # Battle 已释放：停止等待
		if battle.get_tree() == null:
			return   # 已脱离场景树：停止轮询
		await battle.get_tree().process_frame

# 回放中的节奏停顿（可被重开安全打断；process_always=false 故跟随暂停一起停）
func _gap(sec: float) -> void:
	if sec <= 0.0 or battle.get_tree() == null:
		return   # 已脱离场景树：不停顿直接返回
	await battle.get_tree().create_timer(sec, false).timeout
