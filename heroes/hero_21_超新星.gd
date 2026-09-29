extends HeroBase
## 超新星：远程攻击时，将与目标相邻的所有敌人击退1格。若其后方有阻挡不能击退，则伤害它。
## 目标死亡时仍击退/伤害其相邻敌人。
## 【2026-09-28 用户拍板】击退/击穿**不波及障碍物** —— 本技能只作用于单位，目标相邻的障碍不掉耐久。
##   原来跟着"技能对敌人生效时波及到的障碍也掉耐久"那条规则一起做进去了（白游侠散射 / 红帽自爆 /
##   烛火点燃 / 剑气扫过的格都算那一条）；用户实机报「超新星怎么打到目标之后，旁边的障碍物也一起扣血」
##   ⇒ 只摘掉超新星这一处，其余四处照旧。AI 模拟侧 `BattleAI._sim_nova()` 同步摘掉（对拍口径一致）。
## 反过来"主动攻击障碍物"不触发任何英雄技能（规则①不变）。
## 【2026-09-29·用户口径「打一片时只要施法者身上的特效，别人不需要有技能效果」】两个钩子里
##   **逐目标**的 `fx_on_target(v)`（在被打/被推的每个人身上各爆一环）都去掉了 ⇒ 只留 `fx()`（自己身上那圈）。
class_name HeroNova

func on_attack(target: Unit) -> void:
	fx()
	if target == null or not target.alive:
		return
	for v in battle._same_side_adjacent(target):
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)

func on_attack_dead(target: Unit) -> void:
	# 注意：这里**不能**判 target.alive —— 本钩子就是因为"目标已被这一击打死"才被调用，
	# 判了就等于整个函数是死代码（超新星打死人时既不击退/击穿其相邻敌人、也不放技能）。
	if target == null or not is_instance_valid(target):
		return
	for v in battle._same_side_adjacent(target):
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)
