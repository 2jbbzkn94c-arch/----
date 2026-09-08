extends HeroBase
## 超新星：远程攻击时，将与目标相邻的所有敌人击退1格。若其后方有阻挡不能击退，则伤害它。
## 目标死亡时仍击退/伤害其相邻敌人。技能不再作用于障碍物。
class_name HeroNova

func on_attack(target: Unit) -> void:
	fx()
	if target == null or not target.alive:
		return
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name)

func on_attack_dead(target: Unit) -> void:
	if target == null or not target.alive:
		return
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name)
