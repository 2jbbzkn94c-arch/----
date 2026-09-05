extends HeroBase
## 巨剑：攻击后，目标获得[重伤]。
class_name HeroGreatsword

func on_attack(target: Unit) -> void:
	fx()
	if target and target.alive:
		battle._add_status_msg(target, "heavy", "重伤")
