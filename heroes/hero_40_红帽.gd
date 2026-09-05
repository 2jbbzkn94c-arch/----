extends HeroBase
## 红帽：扑街时，对相邻的所有敌人造成13点伤害。强退时不触发。技能不再作用于障碍物。
class_name HeroRedhood

func on_died() -> void:
	for v in battle._adjacent_enemies(unit):
		v.take_damage(13)
		battle.log_message.emit("红帽扑街，波及 %s！" % v.display_name)
