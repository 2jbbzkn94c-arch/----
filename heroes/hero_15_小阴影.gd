extends HeroBase
## 小阴影：攻击时，若目标是全场HP最低的角色或之一，则造成2倍伤害。
class_name HeroShadow

## 【2026-09-24 用户拍板「3」】伤害倍率的**唯一权威**（生产与 AI 共用同一份 ⇒ 不会再各写一份漂移）。
const DmgModel := preload("res://src/DamageModel.gd")

func damage_mult(target: Unit) -> int:
	return DmgModel.hero_damage_mult("hero_15",
		unit.attack_type == DataRegistry.AttackType.RANGED,
		target != null and target.alive and target.skills.has(DataRegistry.Skill.TAUNT),
		target != null and target.alive and battle._is_lowest_hp(target),
		false)

func on_attack(target: Unit) -> void:
	# 2倍(目标为全场HP最低)：命中目标处按其英雄主色爆粒子，直观反馈双倍
	if target != null and is_instance_valid(target) and target.alive and damage_mult(target) == 2:
		play_skill_sfx()
		fx_on_target(target)
