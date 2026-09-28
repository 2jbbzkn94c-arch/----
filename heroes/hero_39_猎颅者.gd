extends HeroBase
## 猎颅者：替补登场时，随机伤害HP最低的敌人之一，并令其获得[眩晕]。
class_name HeroSkullhunter

func on_enter() -> void:
	if battle._hurt_lowest_enemy_stun(unit):
		play_skill_sfx()
		fx()   # 确实打到敌人才演出
		fx_on_target(battle._lowest_enemy(unit))
