extends HeroBase
## 黄金矿工：己方回合开始时，在战场中的空地随机发现一枚金块。
## 黄金矿工可以拾取金块，每拾得一枚，攻击力+1、HP上限和HP+3。
class_name HeroGoldminer

func on_turn_start() -> bool:
	battle._place_gold(unit)
	return true
