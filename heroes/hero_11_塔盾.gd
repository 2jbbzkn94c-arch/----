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
	unit.hp = max(unit.hp - 1, 0)
	unit.hp_changed.emit(unit)
	unit._update_hp_label()
	if unit.hp <= 0:
		unit.die()
	elif unit.is_inside_tree():
		# 演出：塔盾亮起守护特效（扩散环+粒子+飘字），提示这次伤害被格挡
		unit.burst_fx(DataRegistry.hero_fx("hero_11").color, "格挡")
	battle.log_message.emit("%s 的塔盾代替承受 1 点伤害。" % unit.display_name)
	return dmg - 1
