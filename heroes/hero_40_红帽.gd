extends HeroBase
## 红帽：扑街时，对相邻的所有单位（含己方队友）造成13点伤害。强退时不触发。技能不再作用于障碍物。
class_name HeroRedhood

func on_died() -> void:
	# 被[沉默]或[眩晕]期间阵亡：非关键词技能失效，不再触发扑街自爆
	if unit == null or unit.has_status("silence") or unit.has_status("stun"):
		return
	# 自爆演出：双环扩散（橙红主环 + 外扩亮环）
	if unit != null and unit.is_inside_tree():
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.55, 0.25), 1.4, 0.3)
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.85, 0.4), 2.2, 0.45)
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		if battle.grid.distance(unit.cell, v.cell) == 1:
			v.take_damage(13, false, false, "被%s扑街自爆波及" % unit.display_name)
			battle.log_message.emit("红帽扑街，波及 %s！" % v.display_name)
