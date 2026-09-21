extends HeroBase
## 古拉博士：攻击时，如果目标HP大于自己，则治疗自己（回复量=自己攻击力）。
## 判定用的是目标**被攻击前**的 HP（而非受伤后的 HP）。
## 另加一条：必须**真的对这一击造成伤害**才吸血——打在圣盾上（整次被挡）或被坚固免疫到 0 伤害时不回血。
class_name HeroGura

func on_attack(target: Unit) -> void:
	_leech(target)

func on_attack_dead(target: Unit) -> void:
	# 目标被打死时的吸血：同样按攻击前 HP 判定（能打死说明必然造成了伤害）
	_leech(target)

## 吸血结算（on_attack / on_attack_dead 共用）
## 条件：① 这一击确实打掉了目标的血（盾挡下 / 坚固免疫到 0 → 不吸血）
##       ② 目标被攻击前的 HP 高于自己  ③ 自己不是满血（有可回复空间）
func _leech(target: Unit) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.hp >= battle._attack_hp_before:
		return   # 本次攻击没造成伤害：不吸血、也不播演出
	if battle._attack_hp_before > unit.hp and unit.hp < unit.max_hp:
		fx()   # 确实触发吸血才演出
		var amt := maxi(1, unit.effective_atk())
		battle._heal(unit, amt)
		battle.log_message.emit("%s 治疗了自己 %d 点。" % [unit.display_name, amt])
