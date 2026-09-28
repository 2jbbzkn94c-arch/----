extends HeroBase
## 涌电技师：移动后，攻击力+1，然后随机伤害HP最低的敌人之一（可被圣盾格挡），然后伤害自己。
class_name HeroSurgetech

## 【2026-09-28·用户口径「涌电技师的技能伤害放在技能音效播到后面再触发」】
##   技能音效（`英雄音效_整理后/涌电技师/技能音效.ogg`）全长 **2.72 秒**，用解码器量的包络显示
##   最响的一段在 **1.4~1.9 秒**（0.45 / 0.44）⇒ 落伤害点取 1.5 秒（想早/晚就调这个数）。
##   · 施放音与特效仍然**当场**出（`play_skill_sfx()` / `fx()`），只有"伤害结算"往后挪；
##   · 目标在延迟前就选好 ⇒ 这 1.5 秒里局面变了也不会改打别人；
##   · 无头（跑批/探针）不等待，免得白拖时间。
const ELECTRO_HIT_DELAY := 1.5

func on_move() -> void:
	play_skill_sfx()
	fx()
	unit.atk += 1   # 永久叠加，不随回合清零
	unit.perm_atk += 1   # 永久加成，变身时保留
	unit.refresh_stats()
	var low: Unit = battle._lowest_enemy(unit)
	if low != null:
		fx_on_target(low)
		low.set_big_hit_style()
	# 等音效播到后段再落伤害（`Battle._trigger_on_move()` / `_finish_move()` 都是 await 本函数的
	# ⇒ 这一手要等伤害结算完才算结束，中途玩家不能接着操作）
	# ⚠️ 英雄行为脚本是纯对象（不是 Node）⇒ 没有 `get_tree()`，计时器要走 `battle`（Node）。
	if DisplayServer.get_name() != "headless" and ELECTRO_HIT_DELAY > 0.0:
		await battle.get_tree().create_timer(ELECTRO_HIT_DELAY).timeout
	if low != null and is_instance_valid(low) and low.alive:
		low.take_damage(maxi(1, unit.effective_atk()), false, false, "被%s电击" % unit.display_name, true)   # 电击：可被圣盾格挡（消耗盾、免伤）；属攻击伤害，坚固可减
	if unit != null and is_instance_valid(unit) and unit.alive:
		var selfdmg: int = maxi(1, unit.effective_atk())
		unit.take_damage(selfdmg, false, false, "被%s的电击反噬" % unit.display_name)   # 自伤同样可被自身圣盾格挡（非攻击伤害，坚固不减）
