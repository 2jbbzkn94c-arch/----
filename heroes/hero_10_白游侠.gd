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
	if not target._shield_block_status:   # 圣盾挡下整次攻击：不播命中/机制演出
		fx()
		fx_on_target(target)
	battle._add_status_msg(target, StatusDB.FREEZE)
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		v.set_big_hit_style()
		v.take_damage(unit.effective_atk(), false, false, "被%s的散射波及" % unit.display_name, true)
		battle._add_status_msg(v, StatusDB.FREEZE)
	battle.sweep_obstacles_around(target.cell)   # 散射波及到的相邻障碍：各 -1 耐久

func on_attack_dead(target: Unit) -> void:
	if target == null or not target.alive:
		return
	# 死亡目标：仍冰冻其相邻敌人（目标本体已亡，不再冰冻自身）
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		v.set_big_hit_style()
		v.take_damage(unit.effective_atk(), false, false, "被%s的散射波及" % unit.display_name, true)
		battle._add_status_msg(v, StatusDB.FREEZE)
	battle.sweep_obstacles_around(target.cell)   # 散射波及到的相邻障碍：各 -1 耐久
