extends HeroBase
## 巨剑：攻击后，目标获得[重伤]。
class_name HeroGreatsword

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target and target.alive:
		if not target.has_status("shield"):   # 圣盾会挡掉本次[重伤]：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, "heavy", "重伤")
