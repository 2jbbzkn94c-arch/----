extends HeroBase
## 战锤：攻击后，目标攻击力-1、移动力-1，直到回合结束。
class_name HeroWarhammer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target and target.alive:
		battle._add_status_msg(target, "atkdown", "麻痹")
		battle._add_status_msg(target, "freeze", "冰冻")
