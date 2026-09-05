extends HeroBase
## 古拉博士：攻击时，如果目标HP大于自己，则治疗自己（回复量=自己攻击力）。
## 判定用的是目标**被攻击前**的 HP（而非受伤后的 HP），并以攻击前血量为准决定是否吸血。
class_name HeroGura

func on_attack(_target: Unit) -> void:
	# 目标存活时的吸血；HP 用本次攻击结算前的值
	if battle._attack_hp_before > unit.hp:
		fx()   # 确实触发吸血才演出
		var amt := maxi(1, unit.effective_atk())
		battle._heal(unit, amt)
		battle.log_message.emit("%s 治疗了自己 %d 点。" % [unit.display_name, amt])

func on_attack_dead(_target: Unit) -> void:
	# 目标被打死时的吸血：仍按攻击前 HP 判定（攻击前 HP 大于自己则吸血）
	if battle._attack_hp_before > unit.hp:
		fx()   # 确实触发吸血才演出
		var amt := maxi(1, unit.effective_atk())
		battle._heal(unit, amt)
		battle.log_message.emit("%s 治疗了自己 %d 点。" % [unit.display_name, amt])
