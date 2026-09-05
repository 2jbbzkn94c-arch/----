extends HeroBase
## 波盾：替补登场时，令己方所有角色获得[圣盾]。
class_name HeroWaveshield

func on_enter() -> void:
	fx()
	for v in battle.units:
		if v.alive and v.faction == unit.faction:
			v.add_status("shield")
