extends HeroBase
## 古灵精怪：对方回合结束时，随机变为己方队伍中的一名其他角色，暂时获得其所有技能直到下次变化为止。
class_name HeroGremlin

func on_turn_start() -> bool:
	battle._transform(unit)
	return true
