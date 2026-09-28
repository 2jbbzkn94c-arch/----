extends HeroBase
## 医护兵：移动后，治疗相邻队友中HP最低之一（回复量=自己攻击力）。
class_name HeroMedic

func on_move() -> void:
	if battle._heal_adjacent_lowest(unit):
		play_skill_sfx()
		fx()   # 确实治疗到队友才呈现专属特效
