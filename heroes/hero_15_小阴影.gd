extends HeroBase
## 小阴影：攻击时，若目标是全场HP最低的角色或之一，则造成2倍伤害。
class_name HeroShadow

func damage_mult(target: Unit) -> int:
	if target and target.alive and battle._is_lowest_hp(target):
		return 2
	return 1

func on_attack(target: Unit) -> void:
	# 2倍(目标为全场HP最低)：命中目标处按其英雄主色爆粒子，直观反馈双倍
	if target != null and is_instance_valid(target) and target.alive and damage_mult(target) == 2:
		fx_on_target(target)
