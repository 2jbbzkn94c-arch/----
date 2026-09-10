extends HeroBase
## 血锁：己方回合内，你的射程+2，但只能沿直线攻击（仍视为近战攻击）。攻击时将敌人拉到面前一格。
## 拉人的**位移规则**在 Battle._pull_to()（公共原语）；本脚本只负责血锁专属的钩爪演出。
class_name HeroBloodlock

# ---- 钩爪演出参数（血锁专属，想调大小/速度改这里）----
const HOOK_FLY_TIME := 0.16          # "飞出→咬住"的时长（目标被拖回也等这么久才开始）
const HOOK_BODY_SCALE := 0.9         # 钩体相对链环的放大倍数（1.0=同尺度；越小钩子越小）
const CHAIN_COLOR := Color(0.95, 0.16, 0.28)        # 链环主色（鲜红）
const HOOK_METAL := Color(0.894, 0.918, 0.965)      # 钩体金属亮面
const HOOK_OUTLINE := Color(0.094, 0.039, 0.055)    # 钩体深色描边（任何底色上都看得清轮廓）
const HOOK_BLOOD := Color(0.784, 0.118, 0.227)      # 钩根血环（与链子衔接）

## 血锁的钩爪：钩根连着一串链环，从血锁**飞出去**咬住目标，再收链把目标拖到面前。
## head_dist 由 _play_hook_fx 的 tween 驱动（0=未出钩 → 咬住 → 收到近身=拉回完成）。
## 每帧 queue_redraw 重绘，所以链子长度与钩根位置始终跟手。
class BloodHook:
	extends Node2D
	var k := 1.0                 # 随棋盘缩放的系数（基准：棋子半径 54）
	var head_dist := 0.0         # 钩根离血锁的距离（链子画到这里，钩体由此向前伸出）

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var seg := 7.5 * k
		var s := maxf(head_dist, 0.0)
		# 链环：从血锁一路排到钩根（相邻环上下交错，像锁链）
		var n := int(s / seg)
		for i in n:
			var x := i * seg + seg * 0.5
			var oy := (-2.0 if (i % 2 == 0) else 2.0) * k
			draw_arc(Vector2(x, oy), 4.4 * k, 0.0, TAU, 18, CHAIN_COLOR, 2.4 * k, true)
			draw_circle(Vector2(x, oy), 1.6 * k, Color(0.5, 0.05, 0.12))
		if s <= 1.0:
			return   # 还没飞出：只画链子起始段
		# 钩体：按 HOOK_BODY_SCALE 缩放（相对链环的大小）
		var hk := k * HOOK_BODY_SCALE
		var b := Vector2(s, 0.0)                                   # 钩根位置
		var c := b + Vector2(18.0 * hk, 11.0 * hk)                 # 钩身圆心
		var rad := 11.0 * hk
		# 钩身只卷 210°（−90°→120°）：左侧留出**钩口**，是"钩子"而不是一个圆圈
		var pts := PackedVector2Array()
		var steps := 22
		for i in steps + 1:
			var a := deg_to_rad(lerpf(-90.0, 120.0, float(i) / float(steps)))
			pts.append(c + Vector2(cos(a), sin(a)) * rad)
		var tip_pt := pts[pts.size() - 1]
		# 两遍描线：先深色描边，再金属亮面 —— 保证压在棋子/棋盘上轮廓依旧清楚
		for pass_i in 2:
			var oc: Color = HOOK_OUTLINE if pass_i == 0 else HOOK_METAL
			var w_shank := (5.6 if pass_i == 0 else 3.6) * hk
			var w_hook := (5.0 if pass_i == 0 else 3.0) * hk
			draw_line(b, b + Vector2(18.0 * hk, 0.0), oc, w_shank, true)                      # 钩柄
			draw_polyline(pts, oc, w_hook, true)                                             # 钩身（开口卷钩）
			draw_line(tip_pt, b + Vector2(12.0 * hk, 13.0 * hk), oc, w_hook, true)            # 钩尖倒刺（朝钩口内）
		# 钩根血环（与链子衔接处）+ 钩尖亮点
		var r_base := 3.4 * hk
		draw_circle(b, r_base, HOOK_BLOOD)
		draw_arc(b, r_base, 0.0, TAU, 20, HOOK_OUTLINE, 1.8 * hk, true)
		draw_circle(tip_pt, 1.9 * hk, Color(1, 1, 1))

func on_spawn() -> void:
	unit.attack_range += 2
	unit.branch_override = true

# 每回合结束 _clear_statuses 会清掉 branch_override，故本回合开始时必须重新激活，
# 否则血锁从第二回合起不再受限（能攻击直线外目标）。
func on_turn_start() -> bool:
	unit.branch_override = true
	return false

func on_attack(target: Unit) -> void:
	if target == null or not target.alive:
		return
	var from_cell: Vector2i = target.cell   # 记下目标旧格：钩子朝这里飞
	# 位移规则（公共原语，不含演出）：真的拉动了才播钩爪
	if not battle._pull_to(unit, target):
		return
	_play_hook_fx(from_cell, target)

# 血锁专属演出：钩爪连链飞出 → 咬住目标 → 收链把目标拖回面前。
# 先播"飞出+咬住"，再让目标被拖到新格（与收链同步）——看起来就是"钩子钩住人往回拽"。
func _play_hook_fx(from_cell: Vector2i, target: Unit) -> void:
	var bv = battle.board_view
	var start: Vector2 = bv.cell_world_center(unit.cell)
	var tpos: Vector2 = bv.cell_world_center(from_cell)
	var dist := (tpos - start).length()
	if dist < 1.0:
		return
	var board: Node = battle
	var hook := BloodHook.new()
	hook.k = maxf(board.hex_size / 54.0, 0.5)
	hook.position = start
	hook.rotation = (tpos - start).angle()   # 朝目标方向出钩
	hook.head_dist = 0.0
	hook.z_index = 40                         # 压在棋子之上
	board.add_child(hook)
	var hk: float = hook.k * HOOK_BODY_SCALE
	# 咬住距离：钩身圆心在钩根前方 18*hk 处，所以钩根停在"目标前方一段"，
	# 让钩身正好套在目标身上（否则整只钩子会飞过目标）。
	var bite: float = maxf(dist - 18.0 * hk, 6.0)
	var back: float = maxf(board.hex_size * 0.8, 14.0)   # 收回时钩根停在血锁身前
	var t := hook.create_tween()
	# ① 抛出：钩根加速飞向目标
	t.tween_method(func(v: float): hook.head_dist = v, 0.0, bite, 0.12) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	# ② 咬住：短暂停顿（让玩家看清钩子挂上了）
	t.tween_interval(HOOK_FLY_TIME - 0.12)
	# ③ 收链：钩根拖回，同时淡出
	t.tween_method(func(v: float): hook.head_dist = v, bite, back, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(hook, "modulate:a", 0.0, 0.18)
	t.tween_callback(hook.queue_free)
	# 目标被拖回：等钩子咬住后再动，与收链节奏对齐
	if target != null and is_instance_valid(target):
		var dest: Vector2 = bv.cell_world_center(target.cell)
		var tt := target.create_tween()
		tt.tween_interval(HOOK_FLY_TIME)
		tt.tween_property(target, "position", dest, 0.18) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
