extends HeroBase
## 圣诞老人：己方回合开始时，在战场空地随机放置两个随机增益道具。
class_name HeroSanta

func on_turn_start() -> bool:
	battle._place_buff_items(unit, 2)
	play_skill_sfx()   # 道具放下去 = 技能发动
	return true
