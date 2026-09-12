extends HeroBase
## 超新星：远程攻击时，将与目标相邻的所有敌人击退1格。若其后方有阻挡不能击退，则伤害它。
## 目标死亡时仍击退/伤害其相邻敌人。
## 波及到的（目标相邻）障碍物会各掉 1 点耐久——技能对敌人生效时波及障碍要掉耐久；
## 反过来"主动攻击障碍物"不触发任何英雄技能。
class_name HeroNova

func on_attack(target: Unit) -> void:
	fx()
	if target == null or not target.alive:
		return
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)
	battle.sweep_obstacles_around(target.cell)   # 击退/击穿波及到的相邻障碍：各 -1 耐久

func on_attack_dead(target: Unit) -> void:
	# 注意：这里**不能**判 target.alive —— 本钩子就是因为"目标已被这一击打死"才被调用，
	# 判了就等于整个函数是死代码（超新星打死人时既不击退/击穿其相邻敌人、也不波及障碍）。
	if target == null or not is_instance_valid(target):
		return
	for v in battle._same_side_adjacent(target):
		fx_on_target(v)
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)
	battle.sweep_obstacles_around(target.cell)   # 同上：死亡目标处的波及
