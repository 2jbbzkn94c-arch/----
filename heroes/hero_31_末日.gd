extends HeroBase
## 末日：移动后，伤害所有HP小于你的角色（优先敌人，但也会伤到队友）。
class_name HeroDoomsday

func on_move() -> void:
	# 【2026-09-29·用户口径「打一片时只要施法者身上的特效，别人不需要有技能效果」】去掉逐目标爆环
	#   （原来两个循环里各有一句 `fx_on_target(v)`）⇒ 只留末尾那一次 `fx()`（自己身上那圈）。
	var hurt_any := false
	# 先敌人
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction != unit.faction:
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的末日肃清" % unit.display_name, true)
			hurt_any = true
	# 再队友
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction == unit.faction:
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的末日波及" % unit.display_name, true)
			hurt_any = true
	if hurt_any:
		play_skill_sfx()
		fx()   # 确实伤到人才呈现专属特效
