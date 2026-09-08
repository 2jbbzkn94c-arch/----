extends HeroBase
## 复仇者：反击次数无限，反击时造成2倍伤害。
class_name HeroAvenger

func counter_mult() -> int:
	return 2

func infinite_counter() -> bool:
	return true

func on_after_counter() -> void:
	pass   # 反击演出通用即可

## 反击命中(2倍)时，给被反击方(原攻击者)补主色粒子
func on_counter_landed(target: Unit) -> void:
	if target != null and is_instance_valid(target) and target.alive:
		fx_on_target(target)
