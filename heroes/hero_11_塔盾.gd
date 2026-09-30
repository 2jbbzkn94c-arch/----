extends HeroBase
## 塔盾：每当相邻队友受到多于 1 点伤害时，代替承受其中 1 点。
## 由 Battle 在伤害结算**之前**逐个询问会分担伤害的英雄（见 HeroBase.absorb_ally_damage），
## 本脚本负责全部规则与演出；不做事后补救，避免"队友仍扣满 + 塔盾白扣"。
class_name HeroBulwark

## 声明"我会替队友分担伤害"，Battle 才会来问我
func is_damage_absorber() -> bool:
	return true

## 相邻同阵营队友将要受伤时：替他承受 1 点（直接扣血，不再触发塔盾递归/伤害后钩子）
func absorb_ally_damage(target: Unit, dmg: int) -> int:
	if unit == null or not is_instance_valid(unit) or not unit.alive:
		return dmg
	if target == null or not is_instance_valid(target) or not target.alive:
		return dmg
	if target == unit or target.faction != unit.faction:
		return dmg   # 只替自己的队友扛
	if not unit.skill_allowed():
		return dmg   # 被沉默/眩晕：盾牌失效
	var g: HexGrid = battle.grid
	if g.distance(unit.cell, target.cell) != 1:
		return dmg   # 必须紧邻
	play_skill_sfx()   # 上面的守卫都过了 = 这一下一定替他扛，响一声
	# 【2026-09-26 修·用户报「圣盾挡不了塔盾帮队友吸收的伤害」】原来直接扣 hp，绕过了圣盾。
	#   先问盾：有盾 ⇒ 消耗盾并抵消这次代扛（语义与 Unit.take_damage 里的盾一致），仍替队友挡下这 1 点。
	if unit.has_status(StatusDB.SHIELD):
		unit.remove_status(StatusDB.SHIELD)
		unit._float_text("[圣盾]", Color(0.5, 0.8, 1.0), -32, -92)
		battle.log_message.emit("%s 的塔盾替 %s 挡下 1 点（圣盾消耗）。" % [unit.display_name, target.display_name])
		return dmg - 1
	unit.hp = max(unit.hp - 1, 0)
	unit.hp_changed.emit(unit)
	unit._update_hp_label()
	if unit.hp <= 0:
		unit.die()
	elif unit.is_inside_tree():
		# 演出：塔盾亮起守护特效（扩散环+粒子+飘字），提示这次伤害被自己**分担**了 1 点
		# 【2026-09-30·用户口径「将塔盾的技能弹字改为分担」】原来弹的是「格挡」⇒ 现在弹「分担」。
		unit.burst_fx(DataRegistry.hero_fx("hero_11").color, "分担")
	battle.log_message.emit("%s 的塔盾代替承受 1 点伤害。" % unit.display_name)
	return dmg - 1
