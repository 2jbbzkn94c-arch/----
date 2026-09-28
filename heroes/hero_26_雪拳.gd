extends HeroBase
## 雪拳：移动后，令相邻敌人获得[冰冻]。
class_name HeroSnowfist

func on_move() -> void:
	var enemies: Array = battle._adjacent_enemies(unit)
	if enemies.size() == 0:
		return   # 无相邻敌人：技能未生效，不演出
	play_skill_sfx()
	fx()
	for v in enemies:
		fx_on_target(v)
		battle._add_status_msg(v, StatusDB.FREEZE, true)   # 纯状态施加(无伤害)：穿圣盾，不消耗盾
