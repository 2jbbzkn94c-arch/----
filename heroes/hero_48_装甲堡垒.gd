extends HeroBase
## 装甲堡垒：我方回合开始时，若上一回合没有移动，则获得[坚固]（受到攻击伤害-1，对方回合结束时解除）。
class_name HeroArmoredFortress

func on_turn_start() -> bool:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return false
	# 上一回合没有移动 -> 挂[坚固]；移动过 -> 清除（避免累积）
	if not unit.moved_last_turn:
		if not unit.has_status("solid"):
			unit.add_status("solid")
			battle.log_message.emit("%s 上一回合未移动，获得[坚固]。" % unit.display_name)
	else:
		if unit.has_status("solid"):
			unit.remove_status("solid")
	return unit.has_status("solid")
