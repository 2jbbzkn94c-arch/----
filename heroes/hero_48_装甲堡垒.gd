extends HeroBase
## 装甲堡垒：我方回合结束时，若本回合没有移动，则获得[坚固]（受到攻击伤害-1）。
## [坚固] 持续整个对方回合（敌方攻击时-1伤），到下一个我方回合开始时清除。
class_name HeroArmoredFortress

# 回合开始：清掉上一轮留下的[坚固]（它覆盖整个对方回合，此刻已到期）
func on_turn_start() -> bool:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return false
	if unit.has_status("solid"):
		unit.remove_status("solid")
	return false

# 回合结束：本回合没移动 -> 挂[坚固]；移动过 -> 确保清除
func on_turn_end() -> bool:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return false
	if not unit.moved_this_turn:
		if not unit.has_status("solid"):
			unit.add_status("solid")
			battle.log_message.emit("%s 本回合未移动，获得[坚固]。" % unit.display_name)
	else:
		if unit.has_status("solid"):
			unit.remove_status("solid")
	return unit.has_status("solid")
