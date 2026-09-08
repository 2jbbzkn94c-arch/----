extends HeroBase
## 毒蛇淑女：攻击后，目标获得[猛毒]。
## 规则：攻击力被减为 0（如被麻痹）时，本次攻击打不出伤害，不再附加[猛毒]。
class_name HeroViper

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if unit.effective_atk() <= 0:
		return   # 攻击力为 0：未造成伤害，无法附加[猛毒]
	if target and target.alive:
		if not target._shield_block_status:   # 圣盾挡下整次攻击：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, "poison", "猛毒")
