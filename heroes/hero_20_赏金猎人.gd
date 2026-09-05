extends HeroBase
## 赏金猎人：远程攻击时，如果目标有\<嘲讽\>，则造成2倍伤害。
class_name HeroBounty

func damage_mult(target: Unit) -> int:
	if target and target.alive and unit.attack_type == DataRegistry.AttackType.RANGED \
			and target.skills.has(DataRegistry.Skill.TAUNT):
		return 2
	return 1
