extends HeroBase
## 烛火：移动后，伤害所有相邻的敌人，并点燃相邻的障碍物（障碍物受等量耐久伤害）。
class_name HeroCandle

func on_move() -> void:
	var enemies: Array = battle._adjacent_enemies(unit)
	var has_target := enemies.size() > 0
	# 火焰蔓延到相邻障碍物（燃损耐久 1 点/次；无相邻敌人时也要烧障碍）
	# 走公共原语：与"技能波及障碍"（剑气穿透/散射/自爆）同一套规则，返回被波及的障碍数
	if battle.sweep_obstacles_around(unit.cell) > 0:
		has_target = true
	if not has_target:
		return   # 无相邻敌人也无相邻障碍：技能未生效，不演出
	play_skill_sfx()
	fx()   # 确实烫到目标时才呈现专属特效
	for v in enemies:
		fx_on_target(v)
		v.set_big_hit_style()
		v.take_damage(unit.effective_atk(), false, false, "被%s的烛火灼烧" % unit.display_name, true)
