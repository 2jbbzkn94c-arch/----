extends HeroBase
## 德鲁伊：己方回合结束时，治疗所有其他队友（回复量=自己当前的攻击力）。
class_name HeroDruid

func on_turn_end() -> bool:
	var amt := maxi(1, unit.effective_atk())   # 与医护兵口径一致：取"当前有效攻击"
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit and v.hp < v.max_hp:
			battle._heal(v, amt)
	return true
