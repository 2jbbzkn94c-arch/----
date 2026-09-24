extends HeroBase
## 赏金猎人：远程攻击时，如果目标有\<嘲讽\>，则造成2倍伤害。
class_name HeroBounty

## 【2026-09-24 用户拍板「3」】伤害倍率的**唯一权威**（生产与 AI 共用同一份 ⇒ 不会再各写一份漂移）。
const DmgModel := preload("res://src/DamageModel.gd")

func damage_mult(target: Unit) -> int:
	return DmgModel.hero_damage_mult("hero_20",
		unit.attack_type == DataRegistry.AttackType.RANGED,
		target != null and target.alive and target.skills.has(DataRegistry.Skill.TAUNT),
		false,
		false)

func on_attack(target: Unit) -> void:
	if target != null and is_instance_valid(target) and target.alive and damage_mult(target) == 2:
		fx_on_target(target)   # 对嘲讽目标2倍：命中目标处主色粒子
