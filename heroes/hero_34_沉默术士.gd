extends HeroBase
## 沉默术士：远程攻击后，目标获得[沉默]。
class_name HeroSilencer

func on_attack(target: Unit) -> void:
	fx()
	if target and target.alive:
		battle._add_status_msg(target, "silence", "沉默")
