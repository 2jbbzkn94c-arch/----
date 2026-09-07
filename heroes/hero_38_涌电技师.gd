extends HeroBase
## 涌电技师：移动后，攻击力+1，然后随机伤害HP最低的敌人之一（可被圣盾格挡），然后伤害自己。
class_name HeroSurgetech

func on_move() -> void:
	fx()
	unit.atk += 1   # 永久叠加，不随回合清零
	unit.perm_atk += 1   # 永久加成，变身时保留
	unit.refresh_stats()
	var low: Unit = battle._lowest_enemy(unit)
	if low != null:
		low.take_damage(maxi(1, unit.effective_atk()), false, false, "被%s电击" % unit.display_name)   # 电击：可被圣盾格挡（消耗盾、免伤）
	var selfdmg: int = maxi(1, unit.effective_atk())
	unit.take_damage(selfdmg, false, false, "被%s的电击反噬" % unit.display_name)   # 自伤同样可被自身圣盾格挡
