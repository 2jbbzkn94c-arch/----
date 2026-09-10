extends HeroBase
## 黄金矿工：己方回合开始时，在战场中的空地随机发现一枚金块。
## 黄金矿工可以拾取金块，每拾得一枚，攻击力+1、HP上限和HP+3。
class_name HeroGoldminer

func on_turn_start() -> bool:
	battle._place_gold(unit)
	return true

## 只有黄金矿工能拾取金矿（其他单位踩到不消费、金矿留在格上）
func can_pickup_gold() -> bool:
	return true
