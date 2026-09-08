extends HeroBase
## 沉默术士：远程攻击后，目标获得[沉默]。
class_name HeroSilencer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target and target.alive:
		if not target._shield_block_status:   # 圣盾挡下整次攻击：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, "silence", "沉默")
