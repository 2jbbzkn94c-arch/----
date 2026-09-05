extends HeroBase
## 毒蛇淑女：攻击后，目标获得[猛毒]。
class_name HeroViper

func on_attack(target: Unit) -> void:
	fx()
	if target and target.alive:
		battle._add_status_msg(target, "poison", "猛毒")
