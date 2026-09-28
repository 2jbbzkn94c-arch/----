extends HeroBase
## 德鲁伊：己方回合结束时，治疗所有其他队友（回复量=自己当前的攻击力）。
class_name HeroDruid

func on_turn_end() -> bool:
	var amt := maxi(1, unit.effective_atk())   # 与医护兵口径一致：取"当前有效攻击"
	var healed_any := false
	for v in battle.units:
		if v.alive and v.faction == unit.faction and v != unit and v.hp < v.max_hp:
			battle._heal(v, amt)
			healed_any = true
	if healed_any:
		play_skill_sfx()
		unit.float_tag_text("治疗", Color(0.45, 0.9, 0.6))   # 施加回复方弹"治疗"
	return false   # 治疗演出由上面的"治疗"文字承担，不再触发通用"被动"闪烁
