extends HeroBase
## 雪拳：移动后，令相邻敌人获得[冰冻]。
class_name HeroSnowfist

func on_move() -> void:
	var enemies: Array = battle._adjacent_enemies(unit)
	if enemies.size() == 0:
		return   # 无相邻敌人：技能未生效，不演出
	play_skill_sfx()
	fx()
	# 【2026-09-29·用户口径「打一片时只要施法者身上的特效，别人不需要有技能效果」】去掉逐目标爆环
	for v in enemies:
		battle._add_status_msg(v, StatusDB.FREEZE, true)   # 纯状态施加(无伤害)。第三参 pierce_shield 是历史遗留：
														   # 【2026-10-01】盾已不再挡任何状态，传不传都一样
