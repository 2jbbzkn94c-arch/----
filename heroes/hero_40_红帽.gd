extends HeroBase
## 红帽：扑街时，对相邻的所有敌人造成13点伤害。强退时不触发。技能不再作用于障碍物。
class_name HeroRedhood

func on_died() -> void:
	# 自爆演出：双环扩散（橙红主环 + 外扩亮环）
	if unit != null and unit.is_inside_tree():
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.55, 0.25), 1.4, 0.3)
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.85, 0.4), 2.2, 0.45)
	for v in battle._adjacent_enemies(unit):
		v.take_damage(13)
		battle.log_message.emit("红帽扑街，波及 %s！" % v.display_name)
