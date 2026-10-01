extends HeroBase
## 战锤：攻击后，目标攻击力-1、移动力-1，直到目标方回合结束（即施加者的对方回合结束）。
class_name HeroWarhammer

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target and target.alive:
		if not target._shield_block_status:   # 这一击一点血都没打掉（不算打中）：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, StatusDB.ATKDOWN)
		battle._add_status_msg(target, StatusDB.FREEZE)
