extends HeroBase
## 暗域：攻击时和对象交换位置。目标被打死时，占据其空出的格子。
class_name HeroDarkrealm

func on_attack(target: Unit) -> void:
	fx()
	if target and target.alive:
		battle._swap_units(unit, target)

func on_attack_dead(target: Unit) -> void:
	if target and not target.alive:
		battle._occupy_dead_cell(unit, target)
