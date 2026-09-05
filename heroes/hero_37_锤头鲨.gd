extends HeroBase
## 锤头鲨：每当敌人受到一次伤害（AOE算一次），你的攻击力+1，直到回合结束。
## 反击伤害不触发。
class_name HeroHammerhead

func on_someone_damaged(target: Unit, _amount: int) -> void:
	if target == null or not target.alive:
		return
	if target._was_counter_damage:
		return   # 反击伤害不触发
	if target.faction == unit.faction:
		return   # 只对敌人触发的受伤生效
	unit.atk_buff += 1
	unit.refresh_stats()
