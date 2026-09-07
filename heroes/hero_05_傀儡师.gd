extends HeroBase
## 傀儡师：己方回合开始时，令所有敌人向随机方向移动一格（无位可移则跳过）。
class_name HeroPuppeteer

func on_turn_start() -> bool:
	for v in battle.units.duplicate():
		if v.alive and v.faction != unit.faction:
			battle._random_step(v)   # 可能把敌人推上炸弹引爆致死：用快照遍历防漏
	return true
