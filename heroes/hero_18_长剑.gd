extends HeroBase
## 长剑：攻击敌人时，一并伤害目标身后直线上的所有敌人。
## 目标死亡时剑气仍沿其身后穿透。技能不再作用于障碍物。
class_name HeroSwordline

# ---- 剑气演出（长剑专属；配色/尺寸想调改这里）----
const QI_COLOR := Color(0.92, 0.98, 1.0, 1.0)   # 银蓝亮弧
const QI_SCALE := 1.5                            # 整体放大便于看清

## 长剑剑光：一道银蓝月弯型剑气，扫过直线并淡出。
class SwordCrescent:
	extends Node2D

	func _draw() -> void:
		if not (is_finite(position.x) and is_finite(position.y) and is_finite(rotation)):
			return
		# 单层亮弧(宽刃)，两端渐尖
		_crescent_band(66.0, QI_COLOR, 15.0, 70.0)

	func _crescent_band(radius: float, color: Color, base_w: float, half_deg: float) -> void:
		# 沿弧线分 30 段,两端宽度递减到接近尖点,中间最宽;张角=2*half_deg
		var a0 := deg_to_rad(-half_deg)
		var a1 := deg_to_rad(half_deg)
		var seg := 30
		var prev := a0
		for i in seg + 1:
			var ang := lerpf(a0, a1, float(i) / float(seg))
			var u := absf(lerpf(-1.0, 1.0, float(i) / float(seg)))
			var w := maxf(0.8, base_w * (1.0 - 0.88 * u * u))   # 两端收敛到 ~0.12 宽度
			draw_arc(Vector2.ZERO, radius, prev, ang, 2, color, w, true)
			prev = ang

func on_attack(target: Unit) -> void:
	# 演出由本脚本的月弯剑气承担，不再叠施法者环与命中粒子
	if target and target.alive:
		_spawn_qi_toward(target.cell)
		battle._pierce_back(unit, target)

func on_attack_dead(target: Unit) -> void:
	if target and not target.alive:
		_spawn_qi_toward(target.cell)
		battle._pierce_line(unit, target.cell)

# 剑气演出：一道银蓝月弯从长剑沿目标方向直线扫到尽头后消失（月弯型）
func _spawn_qi_toward(target_cell: Vector2i) -> void:
	var g: HexGrid = battle.grid
	var bv: BoardView = battle.board_view
	var a: Vector2i = g.axial_of(unit.cell)
	var t: Vector2i = g.axial_of(target_cell)
	var step: Vector2i = t - a
	if step == Vector2i.ZERO:
		return
	var start: Vector2 = bv.cell_world_center(unit.cell)
	var end: Vector2 = bv.cell_world_center(g.offset_of(a + step * 8))
	var dir: Vector2 = end - start
	var qi := SwordCrescent.new()
	qi.position = start
	qi.rotation = dir.angle()
	qi.scale = Vector2(QI_SCALE, QI_SCALE)
	qi.z_index = 40
	var board: Node = battle
	board.add_child(qi)
	var dur: float = clampf(dir.length() * 0.022, 0.55, 1.2)   # 适中偏慢
	var tw: Tween = qi.create_tween()
	tw.tween_property(qi, "position", end, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(qi.queue_free)
