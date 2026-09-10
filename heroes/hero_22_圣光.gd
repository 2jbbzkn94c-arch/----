extends HeroBase
## 圣光：**敌方回合**里，一名己方英雄受到伤害后，其获得[圣盾]（一回合限一次）。
## 触发时机限定在"敌方回合"：己方回合里挨打（反击、猛毒、回合烧血等）不给盾。
## 已有盾的目标不消耗次数（通常是同一次受伤已被另一名圣光先加上盾），名额留给下一位伤者。
## 给盾延迟到本次攻击整体结算完成（下一帧）再发：否则盾会赶在同一次攻击后续附加的状态
## （毒蛇的猛毒等）之前被套上，把本该中的状态也挡掉了。
class_name HeroLight

func on_someone_damaged(target: Unit, _amount: int) -> void:
	if target == null or not target.alive:
		return
	if target.faction != unit.faction:
		return   # 只护己方
	# 只在**敌方回合**触发：当前行动方与本单位所属阵营相同时 = 己方回合，不给盾
	if battle.side_faction(GameState.active_side) == unit.faction:
		return
	if unit.once_this_turn:
		return   # 一回合限一次
	if target.has_status(StatusDB.SHIELD):
		return   # 目标已有盾：本次不消耗次数，留给下一位伤者
	unit.once_this_turn = true
	# 延迟到本次攻击整体结算完成(下一帧)再给盾：否则盾会赶在同一次攻击
	# 后续附加的状态(毒蛇的猛毒等)之前被套上，把本该中的状态也挡掉了。
	# 用实例id捕获，避免 lambda 捕获的单位先被释放导致 "capture was freed" 报错。
	var my_id: int = unit.get_instance_id()
	var tgt_id: int = target.get_instance_id()
	var btl_id: int = battle.get_instance_id()
	var grant := func():
		var m := instance_from_id(my_id) as Unit
		var t := instance_from_id(tgt_id) as Unit
		var btl := instance_from_id(btl_id)
		if m == null or t == null or not m.alive or not t.alive or t.faction != m.faction:
			return
		if btl == null or not is_instance_valid(btl):
			return
		t.add_status(StatusDB.SHIELD)
		# 授予演出克制不遮挡伤害数字：仅外扩细光环 + 高处小字(不做中心白闪/粒子)
		btl._boom_ring_fx(t.cell, Color(0.6, 0.9, 1.0), 1.25, 0.4)
		t.float_tag_text("圣盾", Color(0.65, 0.9, 1.0))
	grant.call_deferred()
	battle.log_message.emit("圣光为 %s 施加[圣盾]。" % target.display_name)
