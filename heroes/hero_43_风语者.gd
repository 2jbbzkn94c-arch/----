extends HeroBase
## 风语者：所有其他队友移动力 +1，且移动后回复等同于本次移动距离的 HP。
## 光环的发放 / 收回 / 补发全部在本脚本；Battle 只在对应时机派发通用钩子（不认具体英雄）。
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
		var u := instance_from_id(k) as Unit
		if u == null or not is_instance_valid(u):
			_aura_given.erase(k)   # 顺手清掉已释放单位的记录
	_aura_given[who.get_instance_id()] = true

## 每方回合开始：给其他队友 +1 移动力（不含自己）
func on_turn_start() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.move_buff += 1
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
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == unit.faction and v.hero_id != "hero_43":
			v.move_buff += 1
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
		var v := instance_from_id(k) as Unit
		if v != null and is_instance_valid(v) and v.alive and v.move_buff > 0:
			v.move_buff -= 1
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
