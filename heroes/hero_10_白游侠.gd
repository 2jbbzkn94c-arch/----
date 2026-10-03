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

## 【2026-10-03·用户口径「击杀特效要在杀死人之前」】击杀预告：这一枪**散射**会波及谁。
##   判据与上面两个循环**逐条同一把尺**：同一批目标（`_same_side_adjacent(target)` = 与目标同阵营
##   的相邻单位，两个钩子给的是同一批）、同一个伤害数（`effective_atk()`）、`is_attack = true`。
##   ⇒ `Battle._do_attack()` 开打前拿它播完这些人的击杀卡面，之后那段同步循环照旧立刻结算
##   （目标活着走 `on_attack`、被这一枪打死走 `on_attack_dead`，两个分支的波及名单相同）。
##   ⚠️ 纯查询：不改状态、不动随机源。
func side_hits_on_attack(target: Unit) -> Array:
	var out: Array = []
	if target == null or not is_instance_valid(target):
		return out
	var dmg: int = unit.effective_atk()
	for v in battle._same_side_adjacent(target):
		out.append({ "v": v, "dmg": dmg, "atk": true })
	return out

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
