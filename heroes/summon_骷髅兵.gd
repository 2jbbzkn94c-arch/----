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
		# 【2026-09-30·用户实机贴的报错】
		#   `Error calling method from CallbackTweener: 'Node2D(Battle.gd)::_on_unit_died':
		#    Cannot convert argument 1 from Object to Object.`
		#   病灶：回调是 **0.25 秒后**才响的，而这段路上骷髅完全可能先被释放（同一时刻被反击打死 /
		#   主人阵亡走 `_skeleton_owner_gone` / 重开与换边 `_clear_all_units()`）⇒ 绑进去的是
		#   **已释放实例**，而 `_on_unit_died(u: Unit, …)` 的形参带类型标注 ⇒ 引擎在**进入函数体之前**
		#   就转换失败报错（函数体里那句 `is_instance_valid(u)` 根本轮不到）。
		#   改法与 `Unit.die()` / Battle 里其它补间同一套：**补间绑在骷髅自己身上**（它被释放 ⇒
		#   这趟淡出随之作废）+ 回调里用 `WeakRef` 重新取、校验后再调。
		var w_unit: WeakRef = weakref(unit)
		var t: Tween = unit.create_tween()
		if t == null:
			battle._on_unit_died(unit)   # 兜底：拿不到补间（不在树里）就直接收尾
			return false
		t.tween_property(unit, "modulate:a", 0.0, 0.25)
		t.tween_callback(func():
			var u = w_unit.get_ref()
			if u != null and is_instance_valid(u):
				battle._on_unit_died(u))
	return false
