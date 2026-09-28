extends HeroBase
## 烈焰祭司：己方回合开始时，所有其他队友攻击力+1，直到回合结束。
class_name HeroFlamepriest

func on_turn_start() -> bool:
	var buffed := 0
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit:
			v.atk_buff += 1
			buffed += 1
	if buffed > 0:
		play_skill_sfx()   # 真的给队友加成才响
	return true
