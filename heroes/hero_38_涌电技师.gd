extends HeroBase
## 涌电技师：移动后，攻击力+1，然后随机伤害HP最低的敌人之一，然后伤害自己。
class_name HeroSurgetech

func on_move() -> void:
	fx()
	unit.atk += 1   # 永久叠加，不随回合清零
	unit.perm_atk += 1   # 永久加成，变身时保留
	unit.refresh_stats()
	var low: Unit = battle._lowest_enemy(unit)
	if low != null:
		low.take_damage(maxi(1, unit.effective_atk()), true)   # 电击：真实伤害，无视圣盾
	var selfdmg: int = maxi(1, unit.effective_atk())
	unit.take_damage(selfdmg, true)
