extends HeroBase
## 末日：移动后，伤害所有HP小于你的角色（优先敌人，但也会伤到队友）。
class_name HeroDoomsday

func on_move() -> void:
	var hurt_any := false
	# 先敌人
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction != unit.faction:
			v.take_damage(unit.effective_atk())
			hurt_any = true
	# 再队友
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction == unit.faction:
			v.take_damage(unit.effective_atk())
			hurt_any = true
	if hurt_any:
		fx()   # 确实伤到人才呈现专属特效
