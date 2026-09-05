extends HeroBase
## 死灵法师：己方回合开始时，随机在相邻位置召唤2个骷髅兵（位置不足则少召）。
class_name HeroNecro

func on_turn_start() -> bool:
	battle._summon_skeletons(unit)
	return true
