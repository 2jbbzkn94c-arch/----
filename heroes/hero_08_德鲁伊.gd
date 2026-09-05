extends HeroBase
## 德鲁伊：己方回合结束时，治疗所有其他队友（2点）。
class_name HeroDruid

func on_turn_end() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit and v.hp < v.max_hp:
			battle._heal(v, 2)
	return true
