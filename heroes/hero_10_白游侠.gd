extends HeroBase
## 白游侠：远程攻击时一并伤害与目标相邻的敌人，并使它们获得[冰冻]。
## 目标死亡时同样波及（AOE 于死亡目标上结算）。
## 波及到的（目标相邻）障碍物会各掉 1 点耐久——技能对敌人生效时波及障碍要掉耐久；
## 反过来"主动攻击障碍物"不触发任何英雄技能。
class_name HeroRanger

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target == null or not target.alive:
		return
	if not target._shield_block_status:   # 这一击一点血都没打掉（不算打中）：不播命中/机制演出
		fx()
		# 【2026-09-29·用户口径「打一片时只要施法者身上的特效，别人不需要有技能效果」】
		#   原来这里还有一句 `fx_on_target(target)`（在目标格也爆一环）⇒ 去掉，只留施法者自己那圈。
	battle._add_status_msg(target, StatusDB.FREEZE)
	for v in battle._same_side_adjacent(target):
		v.set_big_hit_style()
		# 【2026-09-30·用户报「技能波及到的目标死亡时候，不弹击杀特效」】散射致死也弹击杀卡面
		battle.kill_intro_side(unit, v, unit.effective_atk(), true)
		v.take_damage(unit.effective_atk(), false, false, "被%s的散射波及" % unit.display_name, true)
		battle._add_status_msg(v, StatusDB.FREEZE)
	battle.sweep_obstacles_around(target.cell)   # 散射波及到的相邻障碍：各 -1 耐久

func on_attack_dead(target: Unit) -> void:
	# 注意：这里**不能**判 target.alive —— 本钩子就是因为"目标已被这一击打死"才被调用，
	# 判了就等于整个函数是死代码（白游侠打死人时不会散射/冰冻其相邻敌人、也不波及障碍）。
	if target == null or not is_instance_valid(target):
		return
	# 死亡目标：仍冰冻其相邻敌人（目标本体已亡，不再冰冻自身）
	for v in battle._same_side_adjacent(target):
		v.set_big_hit_style()
		# 同上：波及致死也弹击杀卡面
		battle.kill_intro_side(unit, v, unit.effective_atk(), true)
		v.take_damage(unit.effective_atk(), false, false, "被%s的散射波及" % unit.display_name, true)
		battle._add_status_msg(v, StatusDB.FREEZE)
	battle.sweep_obstacles_around(target.cell)   # 散射波及到的相邻障碍：各 -1 耐久
