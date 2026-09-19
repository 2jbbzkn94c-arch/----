extends HeroBase
## 伐木工：攻击障碍物时额外减少99耐久。
class_name HeroWoodcutter

func obstacle_damage() -> int:
	# 被[沉默]/[眩晕]时技能失效（语义见 Unit.skill_allowed()："不能触发任何技能"）
	# → 拆墙的额外 99 耐久不生效，退化为 HeroBase 的默认 1（普通一击的障碍耐久）。
	# Battle._impact_obstacle 只判 u.alive 就取本钩子，闸门必须在这里判。
	if not unit.skill_allowed():
		return 1
	# 攻击障碍：攻击力 + 99 耐久
	return battle._attack_damage(unit) + 99
