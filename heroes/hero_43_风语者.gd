extends HeroBase
## 风语者：所有其他队友移动力+1，且移动后回复等同于本次移动距离的HP。
class_name HeroWindspeaker

func on_turn_start() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.move_buff += 1
	return true
