extends HeroBase
## 嬉皮死神：攻击时，如果目标没有与其他敌人相邻，则造成2倍伤害。
class_name HeroJollyreaper

const _FX_COLOR := Color(0.85, 0.35, 1.0)   # 双倍重击：紫粉色色光粒子

func damage_mult(target: Unit) -> int:
	if target and target.alive and battle._is_isolated(target, unit):
		return 2
	return 1

func _double_hit_fx(target: Unit) -> void:
	if target == null or not is_instance_valid(target):
		return
	# 受击方重击反馈：目标格爆出扩散环 + 六向紫粉粒子 + 白闪（不飘字，避免盖住伤害数字）
	target.burst_fx(_FX_COLOR, "")
	# 棋盘层再来一道更醒目的冲击环(色光粒子感更强)
	if battle.has_method("_boom_ring_fx"):
		battle._boom_ring_fx(target.cell, _FX_COLOR, 2.0, 0.55)

func on_attack(target: Unit) -> void:
	# 仅当这次伤害真的打到(目标掉血/死亡)才播双倍演出；被圣盾完全挡下则无效果无演出
	if target == null or not is_instance_valid(target):
		return
	if damage_mult(target) == 2 and (not target.alive or target.hp < battle._attack_hp_before):
		_double_hit_fx(target)

func on_attack_dead(target: Unit) -> void:
	if target != null and battle._is_isolated(target, unit):
		_double_hit_fx(target)
