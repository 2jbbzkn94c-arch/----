extends HeroBase
## 圣光：每回合限一次，一名己方角色受伤后，其获得[圣盾]。
class_name HeroLight

func on_someone_damaged(target: Unit, _amount: int) -> void:
	if target == null or not target.alive:
		return
	if target.faction != unit.faction:
		return
	if unit.once_this_turn:
		return
	if target.has_status("shield"):
		return   # 目标已有盾(通常是同一次受伤被另一名圣光先加上了):本次不消耗次数,留给下一位伤者
	unit.once_this_turn = true
	# 延迟到本次攻击整体结算完成(下一帧)再给盾：否则盾会赶在同一次攻击
	# 后续附加的状态(毒蛇的猛毒等)之前被套上，把本该中的状态也挡掉了。
	var me := unit
	var tgt := target
	var grant := func():
		if is_instance_valid(me) and me.alive and is_instance_valid(tgt) and tgt.alive \
				and tgt.faction == me.faction:
			tgt.add_status("shield")
	grant.call_deferred()
	battle.log_message.emit("圣光为 %s 施加[圣盾]。" % target.display_name)
