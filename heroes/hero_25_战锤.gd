extends HeroBase
## 战锤：攻击后，目标攻击力-1、移动力-1，直到目标方回合结束（即施加者的对方回合结束）。
class_name HeroWarhammer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target and target.alive:
		if not target._shield_block_status:   # 圣盾挡下整次攻击：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, "atkdown", "麻痹")
		battle._add_status_msg(target, "freeze", "冰冻")
