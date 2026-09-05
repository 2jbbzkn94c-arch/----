extends HeroBase
## 长剑：攻击敌人时，一并伤害目标身后直线上的所有敌人。
## 目标死亡时剑气仍沿其身后穿透。技能不再作用于障碍物。
class_name HeroSwordline

func on_attack(target: Unit) -> void:
	fx()
	if target and target.alive:
		battle._pierce_back(unit, target)

func on_attack_dead(target: Unit) -> void:
	if target and not target.alive:
		battle._pierce_line(unit, target.cell)
