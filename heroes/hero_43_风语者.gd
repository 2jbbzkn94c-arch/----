extends HeroBase
## 风语者：所有其他队友移动力 +1（牌面上是 [风语] 状态），且移动后回复等同于本次移动距离的 HP。
## 光环的发放 / 收回 / 补发全部在本脚本；Battle 只在对应时机派发通用钩子（不认具体英雄）。
## ⚠️【2026-09-26】光环从"借 <疾行> 的招牌"改成**独立状态 [风语]**（用户要求：与**本来就有 <疾行>**
##   的队友撞车，看不出这一格移动力是谁给的；角色列表的风语者技能描述也已改成「…获得[风语]」）。
##   状态的生灭与数值 `move_buff` **严格同口径**：这里发/收 + `Battle._clear_statuses()` 回合末一起清。
class_name HeroWindspeaker

## 本回合**实际被本风语者发过光环**的队友（实例 id -> true）。
## 为什么要记账：离场时要收回"本回合发出的 +1 移动力"，但若本回合它被[沉默]/[眩晕]
## （grants_move_aura() 为 false、拿不到光环），on_turn_start / on_enter / on_ally_entered
## 都不会发放，此时再按"全体队友 -1"去收回，就会**凭空扣掉别人发的额度**（多风语者时尤其明显）。
## 只记 id、不记对象引用，避免单位被释放后字典里留下失效引用；每次发放前清理已失效的键。
var _aura_given: Dictionary = {}

## 登记"这个队友本回合被本风语者加过光环"
func _remember_aura(who: Unit) -> void:
	if who == null or not is_instance_valid(who):
		return
	for k in _aura_given.keys():
		# 【2026-09-28 修·录像回放报「Invalid type in utility function "instance_from_id()".
		#   Cannot convert argument 1 from String to int」】本字典的键是**整数实例 id**，而录像快照
		#   （`Battle._dump_script_vars()`）要走 JSON ⇒ **整数键回来会变成字符串**（"12345"）。
		#   键不是整数就一律当"失效记录"清掉：它本来就是**录制那一局**的实例 id，
		#   在回放这一局里必然无效（回放会重新登记自己的 id）。不清就会每次开回合报一行红字。
		if not (k is int):
			_aura_given.erase(k)
			continue
		var u := instance_from_id(k) as Unit
		if u == null or not is_instance_valid(u):
			_aura_given.erase(k)   # 顺手清掉已释放单位的记录
	_aura_given[who.get_instance_id()] = true

## 每方回合开始：给其他队友 +1 移动力（不含自己）
func on_turn_start() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.move_buff += 1
			v.add_status(StatusDB.WIND)   # <风语>：与这份 +1 同步挂上（`add_status` 自己会刷牌面）
			_remember_aura(v)
	return true

## 声明"我提供移动光环"，Battle 才会在队友移动/新人入场时来问我。
## 被[沉默]/[眩晕]时光环失效（语义见 Unit.skill_allowed()："不能触发任何技能（…光环等）"）：
## 这里返回 false，Battle 就不会派发 on_ally_moved（移动回血）与 on_ally_entered（入场上移动力）；
## 分发层（Battle 的移动后光环 / 替补补发光环两处）只判 s.alive，不判 skill_allowed，故闸门必须在这里。
func grants_move_aura() -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	return unit.skill_allowed()

## 替补登场的风语者本人：立刻给在场其他队友补 +1（回合中途替补会错过本回合的 on_turn_start）。
## 注意：与原实现一致，这里**不含**其他风语者。
func on_enter() -> void:
	# 【2026-09-26 修·用户报「风语者登场那回合，全队能多走 1 格」（被冻的猎颅者亮 3 格暴露）】
	#   回合开始的"先补位"阶段登场的风语者：本函数已经给全队 `move_buff += 1`，紧接着**同一轮**
	#   `Battle._run_side_skills()` 还会跑 `on_turn_start()` **再 +1** ⇒ 全队多 1 格（回合末清零 ⇒
	#   只有登场那回合错，下一回合自动正常）。
	#   `Battle._grant_sub_aura_after_enter()` 早就用这两道门挡住了同一件事（"避免 +2"），但那只挡
	#   "**别人替新登场者补发**"那条路；"**风语者自己 `_trigger_on_enter` 主动发**"这条路没挡 ⇒ 这里补上。
	#   ⚠️ 中途换人（两道门都是 false）时照旧发放，那条路仍然需要它。
	if battle._defer_side_skills or battle._start_placing_subs:
		return
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == unit.faction and v.hero_id != "hero_43":
			v.move_buff += 1
			v.add_status(StatusDB.WIND)
			v.refresh_stats()
			_remember_aura(v)

## 队友移动后：移动者回复 = 本次移动距离。
## 风语者本人吃不到自己发的光环；但场上另有风语者时，二者互为"其他队友"、都可回血。
func on_ally_moved(mover: Unit, dist: int) -> void:
	if mover == null or not is_instance_valid(mover) or not mover.alive or dist <= 0:
		return
	if mover.faction != unit.faction:
		return
	if mover == unit and not _another_windspeaker_exists():
		return
	battle._heal(mover, dist)
	battle.log_message.emit("%s 移动 %d 格，风语者令其回复 %d 点生命。"
			% [mover.display_name, dist, dist])

## 队友新入场（替补登场）：给新单位补上 +1 移动力。
## 若新入场者本人就是风语者，则由它的 on_enter() 反向发给队友，这里不重复。
func on_ally_entered(newcomer: Unit) -> void:
	if newcomer == null or not is_instance_valid(newcomer) or not newcomer.alive:
		return
	if newcomer.faction != unit.faction or newcomer.hero_id == "hero_43":
		return
	newcomer.move_buff += 1
	newcomer.add_status(StatusDB.WIND)
	newcomer.refresh_stats()
	_remember_aura(newcomer)

## 离场：立即收回**本回合实际发出的**移动力 +1（光环只有他在场时才存在）。
## 只收回 _aura_given 里记过的队友：本回合被[沉默]/[眩晕]而没发出光环时，这里什么都不做
## （修前是无条件给每个队友 -1，会把别人发的额度也扣掉）。
func on_died() -> void:
	_retract_aura()

## 被主动撤下（换替补）：离场清理必须照做，否则光环会永久留在队友身上
func on_withdrawn() -> void:
	_retract_aura()

func _retract_aura() -> void:
	for k in _aura_given.keys():
		# 【2026-09-28 修·用户贴的 `instance_from_id()` 报错（本行原来是直接 `instance_from_id(k)`）】
		#   与 `_remember_aura()` 里那道门**同一件事**：录像快照要过 JSON ⇒ 字典的**整数键回来会变成字符串**
		#   （"12345"），而 `instance_from_id()` 只收 int ⇒ 回放里风语者一阵亡，本函数就每帧刷红字。
		#   那些键本来就是"录制那一局"的实例 id，在回放这局必然无效 ⇒ 非整数一律跳过（末尾统一清账）。
		if not (k is int):
			continue
		var v := instance_from_id(k) as Unit
		if v != null and is_instance_valid(v) and v.alive and v.move_buff > 0:
			v.move_buff -= 1
			# <风语> 只在"这份 +1 是我给的、且没有别的风语者还加着"时才摘掉（双风语者时留着，与数值同口径）
			if v.move_buff <= 0:
				v.remove_status(StatusDB.WIND)
			v.refresh_stats()
	_aura_given.clear()

# 场上是否存在"另一位"存活风语者（≠ unit）
func _another_windspeaker_exists() -> bool:
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v != unit and v.faction == unit.faction and v.hero_id == "hero_43":
			return true
	return false
