extends HeroBase
## 白游侠：远程攻击时一并伤害与目标相邻的敌人，并使它们获得[冰冻]。
## 目标死亡时同样波及（AOE 于死亡目标上结算）。技能不再作用于障碍物。
class_name HeroRanger

func on_attack(target: Unit) -> void:
	fx()
	if target == null or not target.alive:
		return
	battle._add_status_msg(target, "freeze", "冰冻")
	for v in battle._same_side_adjacent(target):
		v.take_damage(unit.effective_atk())
		battle._add_status_msg(v, "freeze", "冰冻")

func on_attack_dead(target: Unit) -> void:
	if target == null or not target.alive:
		return
	# 死亡目标：仍冰冻其相邻敌人（目标本体已亡，不再冰冻自身）
	for v in battle._same_side_adjacent(target):
		v.take_damage(unit.effective_atk())
		battle._add_status_msg(v, "freeze", "冰冻")
