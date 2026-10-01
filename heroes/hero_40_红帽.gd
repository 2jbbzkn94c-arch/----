extends HeroBase
## 红帽：扑街时，对相邻的**敌方**单位造成13点伤害（**不再误伤己方**）。强退时不触发。
## 自爆波及到的相邻障碍物各掉 1 点耐久（技能波及障碍要掉耐久）。
class_name HeroRedhood

func on_died() -> void:
	# 被[沉默]或[眩晕]期间阵亡：非关键词技能失效，不再触发扑街自爆
	if unit == null or unit.has_status(StatusDB.SILENCE) or unit.has_status(StatusDB.STUN):
		return
	play_skill_sfx()   # 扑街自爆发动（被沉默/眩晕时上面已 return，不响）
	# 自爆演出：双环扩散（橙红主环 + 外扩亮环）
	if unit != null and unit.is_inside_tree():
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.55, 0.25), 1.4, 0.3)
		battle._boom_ring_fx(unit.cell, Color(1.0, 0.85, 0.4), 2.2, 0.45)
	battle.sweep_obstacles_around(unit.cell)   # 自爆波及到的相邻障碍：各 -1 耐久
	for v in battle.units:
		if v == null or not is_instance_valid(v) or not v.alive:
			continue
		# 【2026-10-01·用户「把红帽的技能效果改成只对敌人造成爆炸伤害」】只炸**敌对阵营**：
		#   同阵营（含她自己）一律跳过 —— 原来这里是"相邻的**所有**单位（含己方队友）"。
		if v.faction == unit.faction:
			continue
		if battle.grid.distance(unit.cell, v.cell) == 1:
			v.take_damage(13, false, false, "被%s扑街自爆波及" % unit.display_name)
			battle.log_message.emit("红帽扑街，波及 %s！" % v.display_name)
