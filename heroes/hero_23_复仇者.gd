extends HeroBase
## 复仇者：反击次数无限，反击时造成2倍伤害。
class_name HeroAvenger

func counter_mult() -> int:
	return 2

func infinite_counter() -> bool:
	return true
