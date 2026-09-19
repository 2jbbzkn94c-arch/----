extends HeroBase
## 装甲堡垒：我方回合结束时，若本回合没有移动，则获得[坚固]（受到攻击伤害-1）。
## [坚固] 持续整个对方回合（敌方攻击时-1伤），到下一个我方回合开始时清除。
class_name HeroArmoredFortress

# 我方回合开始时的**非技能**结算：清掉上一轮留下的[坚固]（它覆盖整个对方回合，此刻已到期）。
# 必须挂在 on_own_turn_start_always()（HeroBase.gd:185-189：不受沉默/眩晕影响的那一类）：
# 原来挂在 on_turn_start，而回合开始技被沉默/眩晕时整段不触发，[坚固]会多留一整轮；
# StatusDB 里 SOLID 的 clear_on_turn_end=false、Unit.clear_temp_statuses() 也不清它，
# 所以这里曾经是它唯一的到期清除点。挂到本钩子后：被沉默也照常按时清。
func on_own_turn_start_always() -> void:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return
	if unit.has_status(StatusDB.SOLID):
		unit.remove_status(StatusDB.SOLID)

# 回合开始技：装甲堡垒没有回合开始技（[坚固]的到期清理已挪到 on_own_turn_start_always）
func on_turn_start() -> bool:
	return false

# 回合结束：本回合没移动 -> 挂[坚固]；移动过 -> 确保清除
func on_turn_end() -> bool:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return false
	if not unit.moved_this_turn:
		if not unit.has_status(StatusDB.SOLID):
			unit.add_status(StatusDB.SOLID)
			battle.log_message.emit("%s 本回合未移动，获得[坚固]。" % unit.display_name)
	else:
		if unit.has_status(StatusDB.SOLID):
			unit.remove_status(StatusDB.SOLID)
	return unit.has_status(StatusDB.SOLID)
