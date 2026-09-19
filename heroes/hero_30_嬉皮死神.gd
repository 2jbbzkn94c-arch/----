extends HeroBase
## 嬉皮死神：攻击时，如果目标没有与其他敌人相邻，则造成2倍伤害。
class_name HeroJollyreaper

const _FX_COLOR := Color(0.85, 0.35, 1.0)   # 双倍重击：紫粉色色光粒子

# ---- 专属镰刀演出（本英雄特效写在自己的脚本里）----
const SCYTHE_BLADE := Color(0.4, 0.12, 0.55, 0.95)    # 弯月刃身（紫黑）
const SCYTHE_EDGE := Color(1.0, 0.6, 1.0, 0.98)       # 刃口亮紫
const SCYTHE_WISP := Color(0.7, 0.35, 0.9, 0.35)      # 拖尾刃气
const SCYTHE_GLOW := Color(0.55, 0.2, 0.7, 0.18)      # 光晕

## 嬉皮死神的镰刀刃光：一道大而弯的紫黑色月牙刀刃，向目标横扫收割。
class ScytheBlade:
	extends Node2D

	func _draw() -> void:
		# 防护：节点变换出现非有限值（NaN）时三角剖分会失败，直接跳过绘制
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(rotation)):
			return
		# 弯月镰刀刃（+X，外侧长、内侧短，弧刃更弯更大）
		var blade := PackedVector2Array([
			Vector2(0, 3), Vector2(30, -22), Vector2(64, -16), Vector2(84, 0),
			Vector2(64, 16), Vector2(30, 22), Vector2(0, -3),
		])
		if _poly_ok(blade):
			draw_colored_polygon(blade, SCYTHE_BLADE)
		# 刃口亮紫弧线（刃尖亮、往刃柄渐暗）
		draw_polyline(PackedVector2Array([Vector2(4, 0), Vector2(80, 0)]), SCYTHE_EDGE, 3.0, true)
		# 紫色拖尾刃气（内侧一束流光的弧；末点不再重复首点，避免退化多边形）
		var wisp := PackedVector2Array([
			Vector2(10, 0), Vector2(46, -14), Vector2(76, -6), Vector2(46, 14),
		])
		if _poly_ok(wisp):
			draw_colored_polygon(wisp, SCYTHE_WISP)
		# 光晕
		draw_circle(Vector2(40, 0), 34, SCYTHE_GLOW)

	# 多边形可安全绘制？（顶点有限且能三角剖分，避免 C++ 层 triangulation failed 刷屏/中断）
	func _poly_ok(poly: PackedVector2Array) -> bool:
		for v in poly:
			if not (is_finite(v.x) and is_finite(v.y)):
				return false
		return Geometry2D.triangulate_polygon(poly).size() > 0

func damage_mult(target: Unit) -> int:
	if target and target.alive and battle._is_isolated(target, unit):
		return 2
	return 1

# 出招特效钩子（Battle 在结算伤害前调用）：播专属镰刀横扫。
# 被[沉默]/[眩晕]时技能失效（语义见 Unit.skill_allowed()），**不再播技能专属演出**：
# 与 Battle.gd:3349-3351 把"倍率技的大号伤害数字"也放在 attacker.skill_allowed() 之后同一口径。
# 注意本钩子只在存活单位出手时被调，且单位存活时 skill_allowed() 与沉默/眩晕判定等价。
func play_attack_fx(target: Unit) -> void:
	if not unit.skill_allowed():
		return
	if target == null or not is_instance_valid(target):
		return
	_spawn_scythe(target)

func _double_hit_fx(target: Unit) -> void:
	if target == null or not is_instance_valid(target):
		return
	# 受击方重击反馈：目标格爆出扩散环 + 六向紫粉粒子 + 白闪（不飘字，避免盖住伤害数字）
	target.burst_fx(_FX_COLOR, "")
	# 棋盘层再来一道更醒目的冲击环(色光粒子感更强)
	if battle.has_method("_boom_ring_fx"):
		battle._boom_ring_fx(target.cell, _FX_COLOR, 2.0, 0.55)

# 嬉皮死神：镰刀弧形收割——一道弯月形紫黑色刀刃从死神扫向目标方向，划过弧线后淡出
func _spawn_scythe(target: Unit) -> void:
	var board: Node = battle
	var bv: BoardView = battle.board_view
	var start: Vector2 = bv.cell_world_center(unit.cell)
	var to: Vector2 = bv.cell_world_center(target.cell)
	var dir: Vector2 = to - start
	var scy := ScytheBlade.new()
	scy.position = start
	scy.rotation = dir.angle()
	board.add_child(scy)
	var dur: float = clampf(dir.length() * 0.012, 0.22, 0.45)
	var reach: float = dir.length() + float(board.hex_size) * 0.6
	var t: Tween = scy.create_tween()
	t.tween_property(scy, "position", start + dir.normalized() * reach, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(scy, "scale", Vector2(1.15, 0.7), dur)   # 收割时刀刃略微压
	t.parallel().tween_property(scy, "modulate:a", 0.0, dur)
	t.tween_callback(scy.queue_free)

func on_attack(target: Unit) -> void:
	# 仅当这次伤害真的打到(目标掉血/死亡)才播双倍演出；被圣盾完全挡下则无效果无演出
	if target == null or not is_instance_valid(target):
		return
	if damage_mult(target) == 2 and (not target.alive or target.hp < battle._attack_hp_before):
		_double_hit_fx(target)

func on_attack_dead(target: Unit) -> void:
	if target != null and battle._is_isolated(target, unit):
		_double_hit_fx(target)
