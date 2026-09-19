extends HeroBase
## 复仇者：反击次数无限，反击时造成2倍伤害。
class_name HeroAvenger

func counter_mult() -> int:
	return 2

func infinite_counter() -> bool:
	return true

func on_after_counter() -> void:
	pass   # 反击演出通用即可

## 反击命中(2倍)时，给被反击方(原攻击者)补主色粒子。
## 被[沉默]/[眩晕]时 counter_mult() 已被 Battle._counter_bonus 闸为 1（普通 1 倍反击），
## 这条"2 倍命中粒子"属技能专属演出，同样不该播——语义见 Unit.skill_allowed()。
## 本钩子内自判（Battle 的派发条件不改）：与 Battle.gd:3349-3351 把"倍率技的大号伤害数字"
## 放在 attacker.skill_allowed() 之后是同一口径。只动演出，不动 counter_mult 数值。
func on_counter_landed(target: Unit) -> void:
	if not unit.skill_allowed():
		return
	if target != null and is_instance_valid(target) and target.alive:
		fx_on_target(target)
