extends HeroBase
## 梅林：替补登场时，随机令HP最低的队友之一回复8点HP，然后与其交换位置。
class_name HeroMerlin

func on_enter() -> void:
	if battle._heal_lowest_and_swap(unit):
		play_skill_sfx()
		fx()   # 确实治疗并换位才演出
