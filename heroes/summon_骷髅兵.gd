extends HeroBase
## 骷髅兵（死灵法师召唤物）：回合结束时自然消散。
## 消散是"召唤物寿命"而非技能，因此**被沉默也照常消散**（见 runs_turn_end_while_silenced）。
class_name SummonSkeleton

## 被沉默也要执行 on_turn_end（召唤物寿命不受沉默影响）
func runs_turn_end_while_silenced() -> bool:
	return true

## 己方回合结束：干净淡出离场（不弹伤害数字、不触发被动闪烁），返回 false 表示无技能演出
func on_turn_end() -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	battle.log_message.emit("骷髅兵随回合结束而消散")
	if unit.alive:
		unit.alive = false
		var t: Tween = battle.create_tween()
		t.tween_property(unit, "modulate:a", 0.0, 0.25)
		t.tween_callback(battle._on_unit_died.bind(unit))
	return false
