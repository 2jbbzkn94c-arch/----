extends HeroBase
## 巨剑：攻击后，目标获得[重伤]。
class_name HeroGreatsword

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target and target.alive:
		battle._add_status_msg(target, "heavy", "重伤")
