extends HeroBase
## 嬉皮死神：攻击时，如果目标没有与其他敌人相邻，则造成2倍伤害。
class_name HeroJollyreaper

func damage_mult(target: Unit) -> int:
	if target and target.alive and battle._is_isolated(target, unit):
		return 2
	return 1
