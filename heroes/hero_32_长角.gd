extends HeroBase
## 长角：攻击时，将目标击退1格。如果其后方有阻挡不能击退，则造成2倍伤害。
## 长角自己结算基础伤害（击退则1倍，无法击退则2倍），故 handles_base_damage=true。
class_name HeroLonghorn

func handles_base_damage() -> bool:
	return true

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target == null or not target.alive:
		return
	var kb: bool = battle._knockback(target, unit.cell)
	var hdmg: int = battle._attack_damage(unit) * _bonus_damage(target)
	target.set_big_hit_style()   # 撞击/重击均为技能伤害数字,大号突出
	target.take_damage(hdmg if kb else hdmg * 2, false, false,
			("被%s撞飞" % unit.display_name) if kb else ("被%s的重击重创" % unit.display_name))

func _bonus_damage(target: Unit) -> int:
	return battle._bonus_damage(unit, target)
