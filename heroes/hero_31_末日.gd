extends HeroBase
## 末日：移动后，伤害所有HP小于你的角色（优先敌人，但也会伤到队友）。
class_name HeroDoomsday

func on_move() -> void:
	# 【2026-09-29·用户口径「打一片时只要施法者身上的特效，别人不需要有技能效果」】去掉逐目标爆环
	#   （原来两个循环里各有一句 `fx_on_target(v)`）⇒ 只留末尾那一次 `fx()`（自己身上那圈）。
	var hurt_any := false
	# 先敌人
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction != unit.faction:
			v.set_big_hit_style()
			battle.kill_intro_side(unit, v, unit.effective_atk(), true)   # 波及致死也弹击杀卡面（用户报）
			v.take_damage(unit.effective_atk(), false, false, "被%s的末日肃清" % unit.display_name, true)
			hurt_any = true
	# 再队友
	for v in battle.units:
		if v.alive and v != unit and v.hp < unit.hp and v.faction == unit.faction:
			v.set_big_hit_style()
			battle.kill_intro_side(unit, v, unit.effective_atk(), true)   # 波及致死也弹击杀卡面（用户报）
			v.take_damage(unit.effective_atk(), false, false, "被%s的末日波及" % unit.display_name, true)
			hurt_any = true
	if hurt_any:
		play_skill_sfx()
		fx()   # 确实伤到人才呈现专属特效

## 【2026-10-03·用户口径「击杀特效要在杀死人之前」】击杀预告：移动后这一下肃清会打到谁。
##   判据与上面两个循环**逐条同一把尺**：同一批目标（**先敌人、再队友**，都是"血比我低"的活人，
##   不含自己）、同一个伤害数（`effective_atk()`）、`is_attack = true`。
##   ⇒ `Battle._trigger_on_move()` 在 `on_move()` 之前拿它播完这些人的击杀卡面，之后那段同步循环
##   照旧立刻结算 ⇒ 观感从"人已经死了卡面才出来"变成"卡面滑完 → 才倒下"。⚠️ 纯查询：不改状态。
func side_hits_on_move() -> Array:
	var out: Array = []
	var dmg: int = unit.effective_atk()
	# 顺序与 `on_move()` 一致：先敌人、再队友（多张卡面按这个顺序依次播）
	for pass_faction in [false, true]:
		for v in battle.units:
			if v == null or not is_instance_valid(v) or not v.alive or v == unit:
				continue
			if v.hp >= unit.hp:
				continue
			if (v.faction == unit.faction) != pass_faction:
				continue
			out.append({ "v": v, "dmg": dmg, "atk": true })
	return out
