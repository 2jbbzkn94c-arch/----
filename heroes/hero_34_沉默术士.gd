extends HeroBase
## 沉默术士：远程攻击后，目标获得[沉默]。
class_name HeroSilencer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target and target.alive:
		battle._add_status_msg(target, "silence", "沉默")
