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
		# 【2026-09-30·用户报「技能波及到的目标死亡时候，不弹击杀特效」】电击致死也弹击杀卡面
		#   （自伤那条不弹：那是"把自己电死"，不是击杀）
		# 【2026-10-01·用户报「涌电技师的技能把人电死了，才出击杀特效」】弹的时机从"和伤害同一拍"
		#   改成**先播卡面、再落这一击**（与普攻那条 `_do_attack()` 同款 `await _kill_intro(...)`）——
		#   本函数是协程、`Battle._trigger_on_move()` 又是 await 它的 ⇒ 这里等得起。
		#   ⚠️ `kill_intro_side()`（不 await 那一条）是给"施法者 `on_attack()` 里的**同步**波及循环"用的
		#   （超新星击穿 / 白游侠散射 / 烛火 / 末日 / 红帽自爆 / 长剑剑气）：那里 await 会把整串伤害都推到
		#   卡面播完之后 ⇒ 那几处保持原样，只有这里改成等待。
		var zdmg: int = maxi(1, unit.effective_atk())
		await battle._kill_intro(unit, low, zdmg, true)
		# 卡面演出最长 `Battle.KILL_INTRO_MAX_WAIT`(3s)：期间跳段重演 / 重开会把整盘人换掉 ⇒ 复查再落伤害
		if is_instance_valid(low) and low.alive:
			low.take_damage(zdmg, false, false, "被%s电击" % unit.display_name, true)   # 电击：可被圣盾格挡（消耗盾、免伤）；属攻击伤害，坚固可减
	if unit != null and is_instance_valid(unit) and unit.alive:
		var selfdmg: int = maxi(1, unit.effective_atk())
		unit.take_damage(selfdmg, false, false, "被%s的电击反噬" % unit.display_name)   # 自伤同样可被自身圣盾格挡（非攻击伤害，坚固不减）
