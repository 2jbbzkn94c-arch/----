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
			# 【2026-09-30·用户报「超新星技能波及到的目标死亡时候，不弹击杀特效」】击穿致死也弹卡面
			battle.kill_intro_side(unit, v, unit.effective_atk(), true)
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)

func on_attack_dead(target: Unit) -> void:
	# 注意：这里**不能**判 target.alive —— 本钩子就是因为"目标已被这一击打死"才被调用，
	# 判了就等于整个函数是死代码（超新星打死人时既不击退/击穿其相邻敌人、也不放技能）。
	if target == null or not is_instance_valid(target):
		return
	for v in battle._same_side_adjacent(target):
		if not battle._knockback(v, target.cell):
			v.set_big_hit_style()
			# 同上：波及致死也弹击杀卡面
			battle.kill_intro_side(unit, v, unit.effective_atk(), true)
			v.take_damage(unit.effective_atk(), false, false, "被%s的超新星击穿" % unit.display_name, true)

## 【2026-10-03·用户口径「击杀特效要在杀死人之前」】击杀预告：这一招会**击穿**谁（相邻敌人里
##   "后方被挡住、推不动"的那些）。判据与上面两个循环**逐条同一把尺**：同一批目标（目标同阵营的
##   相邻单位）、同一个伤害数（`effective_atk()`）、`is_attack = true`；只多一层"推不动"的纯计算
##   （`_knockback_dest()` —— 与真正推人时走的是同一个函数）。
##   ⇒ `Battle._do_attack()` 在开打前拿它播完这些人的击杀卡面，之后上面那段同步循环照旧立刻结算。
##   ⚠️ 纯查询：不推人、不结算、不动随机源。⚠️ 这是**预测**（真正结算时前面的受害者可能已经被推走、
##   占住了后面某个人的落点）⇒ 极端情况下与实际差一个人，那一个就退回"伤害落地后补播卡面"。
func side_hits_on_attack(target: Unit) -> Array:
	var out: Array = []
	if target == null or not is_instance_valid(target):
		return out
	var dmg: int = unit.effective_atk()
	for v in battle._same_side_adjacent(target):
		if battle._knockback_dest(v, target.cell).x == -99:
			out.append({ "v": v, "dmg": dmg, "atk": true })
	return out
