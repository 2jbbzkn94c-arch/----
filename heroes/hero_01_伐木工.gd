extends HeroBase
## 伐木工：攻击障碍物时额外减少99耐久。
class_name HeroWoodcutter

func obstacle_damage() -> int:
	# 攻击障碍：攻击力 + 99 耐久
	return battle._attack_damage(unit) + 99
