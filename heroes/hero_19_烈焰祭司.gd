extends HeroBase
## 烈焰祭司：己方回合开始时，所有其他队友攻击力+1，直到回合结束。
class_name HeroFlamepriest

func on_turn_start() -> bool:
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.atk_buff += 1
	return true
