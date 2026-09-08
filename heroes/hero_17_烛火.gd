extends HeroBase
## 烛火：移动后，伤害所有相邻的敌人，并点燃相邻的障碍物（障碍物受等量耐久伤害）。
class_name HeroCandle

func on_move() -> void:
	var enemies: Array = battle._adjacent_enemies(unit)
	var has_target := enemies.size() > 0
	# 火焰蔓延到相邻障碍物（燃损耐久 1 点/次；无相邻敌人时也要烧障碍）
	for n in battle.grid.neighbors(unit.cell):
		if battle.obstacles.has(n):
			has_target = true
			battle._damage_obstacle(n, 1)
	if not has_target:
		return   # 无相邻敌人也无相邻障碍：技能未生效，不演出
	fx()   # 确实烫到目标时才呈现专属特效
	for v in enemies:
		fx_on_target(v)
		v.take_damage(unit.effective_atk(), false, false, "被%s的烛火灼烧" % unit.display_name)
