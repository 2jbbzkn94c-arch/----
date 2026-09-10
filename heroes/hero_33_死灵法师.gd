extends HeroBase
## 死灵法师：己方回合开始时，随机在相邻位置召唤 2 个骷髅兵（位置不足则少召）。
## 阵亡时他召唤的骷髅兵一起消散。
class_name HeroNecro

func on_turn_start() -> bool:
	battle._summon_skeletons(unit)
	return true

## 阵亡：自己召唤的骷髅兵一起消散（骷髅都带召唤者 id summon_owner，逐个淡出离场）
func on_died() -> void:
	if unit == null or not is_instance_valid(unit):
		return
	for s in battle.units.duplicate():
		if s == null or not is_instance_valid(s) or not s.alive:
			continue
		if s.hero_id != "summon_skeleton" or s.summon_owner != unit.id:
			continue
		battle.log_message.emit("%s 召唤的骷髅兵随之消散。" % s.display_name)
		s.alive = false
		var st: Tween = battle.create_tween()
		st.tween_property(s, "modulate:a", 0.0, 0.25)
		st.tween_callback(battle._skeleton_owner_gone.bind(s))
