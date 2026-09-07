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
	target.add_status("shield")
	battle.log_message.emit("圣光为 %s 施加[圣盾]。" % target.display_name)
