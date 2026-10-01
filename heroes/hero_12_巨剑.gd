extends HeroBase
## 巨剑：攻击后，目标获得[重伤]。
class_name HeroGreatsword

func applies_status_on_hit() -> bool:
	return true

func on_attack(target: Unit) -> void:
	if target and target.alive:
		if not target._shield_block_status:   # 这一击一点血都没打掉（不算打中）：不播命中/机制演出
			fx()
			fx_on_target(target)
		battle._add_status_msg(target, StatusDB.HEAVY)
