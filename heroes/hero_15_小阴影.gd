extends HeroBase
## 小阴影：攻击时，若目标是全场HP最低的角色或之一，则造成2倍伤害。
class_name HeroShadow

func damage_mult(target: Unit) -> int:
	if target and target.alive and battle._is_lowest_hp(target):
		return 2
	return 1
