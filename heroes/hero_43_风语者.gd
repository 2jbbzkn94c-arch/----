extends HeroBase
## 风语者：所有其他队友移动力 +1，且移动后回复等同于本次移动距离的 HP。
## 光环的发放 / 收回 / 补发全部在本脚本；Battle 只在对应时机派发通用钩子（不认具体英雄）。
class_name HeroWindspeaker

## 每方回合开始：给其他队友 +1 移动力（不含自己）
func on_turn_start() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.move_buff += 1
	return true

## 声明"我提供移动光环"，Battle 才会在队友移动/新人入场时来问我
func grants_move_aura() -> bool:
	return true

## 替补登场的风语者本人：立刻给在场其他队友补 +1（回合中途替补会错过本回合的 on_turn_start）。
## 注意：与原实现一致，这里**不含**其他风语者。
func on_enter() -> void:
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == unit.faction and v.hero_id != "hero_43":
			v.move_buff += 1
			v.refresh_stats()

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

## 离场：立即收回本回合发给队友的移动力 +1（光环只有他在场时才存在）
func on_died() -> void:
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v.faction == unit.faction and v.hero_id != "hero_43":
			if v.move_buff > 0:
				v.move_buff -= 1
				v.refresh_stats()

# 场上是否存在"另一位"存活风语者（≠ unit）
func _another_windspeaker_exists() -> bool:
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if v != unit and v.faction == unit.faction and v.hero_id == "hero_43":
			return true
	return false
