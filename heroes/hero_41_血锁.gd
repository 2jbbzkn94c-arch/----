extends HeroBase
## 血锁：己方回合内，你的射程+2，但只能沿直线攻击（仍视为近战攻击）。攻击时将敌人拉到面前一格。
## **致死也会把尸体拉到面前（墓碑因此立在血锁面前那格）**：位移本身不判生死，只有落点的
## 炸弹/道具副作用才分死活（见 Battle._pull_to）。
## 拉人的**位移规则**在 Battle._pull_to()（公共原语）；本脚本只负责血锁专属的钩爪演出。
class_name HeroBloodlock

# ---- 钩爪演出参数（血锁专属，想调大小/速度改这里）----
const HOOK_FLY_TIME := 0.16          # "飞出→咬住"的时长（目标被拖回也等这么久才开始）
const HOOK_BODY_SCALE := 0.9         # 钩体相对链环的放大倍数（1.0=同尺度；越小钩子越小）
const CHAIN_COLOR := Color(0.95, 0.16, 0.28)        # 链环主色（鲜红）
const HOOK_METAL := Color(0.894, 0.918, 0.965)      # 钩体金属亮面
const HOOK_OUTLINE := Color(0.094, 0.039, 0.055)    # 钩体深色描边（任何底色上都看得清轮廓）
const HOOK_BLOOD := Color(0.784, 0.118, 0.227)      # 钩根血环（与链子衔接）
# ---- 被拉者"拖回"的时序（只影响被拉者的位移动画；钩爪本身的三段节奏不受影响）----
const HOOK_DRAG_TIME := 0.18         # 活人：等钩子咬住（0.16s）后开拖，0.18s 拖到新格（与收链 0.16→0.34 同步）
const HOOK_DEAD_DRAG_DELAY := 0.06   # 已死目标：起拖提前到 0.06s——尸体 0.3s 就淡完，仍等 0.16s 才动就看不见了
const HOOK_DEAD_DRAG_TIME := 0.20    # 已死目标：0.06s 起拖 → 0.26s 拖到新格，赶在尸体被释放（0.3s）之前收尾

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

## 身份类状态位：血锁"只能沿直线攻击"是身份机制，不随回合清理/变身失效（否则一漏激活就不直线了）
func refresh_identity() -> void:
	super.refresh_identity()
	unit.branch_override = true

## 靠钩爪勾拉（射程+2 直线）：不做"前冲再弹回"的出招动画，演出交给钩爪
func skips_lunge_anim() -> bool:
	return true

## 【2026-09-30·用户口径「血锁贴身不拉人的时候也要刀光」】拉得动才有钩爪演出：
##   `Battle._pull_to()` 在**已经贴身**（距离 ≤1）时直接返回 false ⇒ 连钩爪都不出、画面上什么都没有。
##   这里如实报"这一击有没有位移演出"：贴身为 false ⇒ Battle 会补一道**原地刀光**
##   （见 `HeroBase.melee_has_displace_fx`）；距离 ≥2 为 true ⇒ 钩爪自己就是演出，不再叠刀光。
##   ⚠️ 判据必须与 `_pull_to()` 开头那句一致（两边都是"距离 ≤1 = 拉不动"）。
func melee_has_displace_fx(target: Unit) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if battle == null or battle.grid == null:
		return false
	return battle.grid.distance(unit.cell, target.cell) > 1

## 【2026-09-23 新增·与暗域同一处修复】结算后钩爪整段还要放 0.34s
##   （飞出 0→0.12 / 咬住 →0.16 / 收链 + 把目标拖到位 →0.34，见 `_play_hook_fx` 的时间轴）
##   ⇒ 反击要等它放完再加标准停顿，否则"拖人还没到位反击就冲上来了"。
func attack_settle_delay() -> float:
	return 0.34

# ---- 射程 +2 的沉默/眩晕退化（照坠炮手的 suppressed_attack_range 那套）----
# 为什么需要它：on_spawn() 把 +2 硬写进了 unit.attack_range（出生一次性），
# 但"射程+2"是技能效果、会随沉默/眩晕失效；直接改 attack_range 会让它永久生效。
# 这里声明退化值 1（= 基础近战射程），Battle._effective_range_at / _effective_attack_range
# 在 `not u.mortar_active()` 时会取本钩子（Battle.gd:2435-2443 / 2463-2471），
# 于是沉默/眩晕期间实际射程读数为 1（够不到 2~3 格外的目标），解控后自动恢复 3（field 未被改动，无需还原）。
#
# 为什么与 Unit.gd 的字段注释不冲突：那条注释说的是"<射程2>且只能直线攻击是身份"，
# 其中**身份部分是 branch_override（只能直线攻击）**——它继续由 refresh_identity() 维持、不受沉默影响；
# 而"额外 +2 射程"是从钩爪技能来的加成，与坠炮手"全场射程是身份但被沉默时退化为 2"同一处理口径。
# 参照 precedent：Unit.mortar_active() 把"存活 + 身份位 + skill_allowed()"三者一起判。
func suppressed_attack_range() -> int:
	if unit == null or not is_instance_valid(unit):
		return -1
	if unit.skill_allowed():
		return -1   # 技能有效：用 unit.attack_range（出生时已 +2 = 3）
	return 1        # 被[沉默]/[眩晕]：退回基础近战射程

# 每回合结束 _clear_statuses 会清掉 branch_override，故本回合开始时必须重新激活，
# 否则血锁从第二回合起不再受限（能攻击直线外目标）。
func on_turn_start() -> bool:
	unit.branch_override = true
	return false

func on_attack(target: Unit) -> void:
	_pull_with_hook(target)

## 目标**被这一击打死**时也要拉：尸体照样被拉到面前，墓碑因此立在血锁面前那格。
## 必须挂在这里——Battle._trigger_on_attack 对已死目标是走 on_attack_dead 的（不走 on_attack），
## 只去掉 on_attack 里的存活守卫并不会让致死拉人生效。
func on_attack_dead(target: Unit) -> void:
	_pull_with_hook(target)

# 拉人 + 钩爪演出的公共实现（活人 / 致死同一条路径）。
# 位移规则在 Battle._pull_to（它本身不判生死）；真的拉动了才播钩爪，致死也照常播（钩住→拖回）。
func _pull_with_hook(target: Unit) -> void:
	if target == null:
		return
	var from_cell: Vector2i = target.cell   # 记下目标旧格：钩子朝这里飞
	if not battle._pull_to(unit, target):
		return
	play_skill_sfx()   # 真的把人拉动（或致死拖尸）才响
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
	# 目标被拖回：等钩子咬住后再动，与收链节奏对齐。
	# **已死目标例外**：尸体节点 0.3s 就淡完（随后被释放），若仍等 0.16s（收链开始）才动，
	# "拖尸"几乎看不见（0.16s 时 alpha≈0.47）。所以已死时把起拖提前到 HOOK_DEAD_DRAG_DELAY、
	# 并在释放前拖完；**钩爪本身的三段（飞出 0→0.12 / 咬住 0.12→0.16 / 收链 0.16→0.34）一个字不变**。
	if target != null and is_instance_valid(target):
		var dest: Vector2 = bv.cell_world_center(target.cell)
		var dying: bool = not target.alive
		var tt := target.create_tween()
		tt.tween_interval(HOOK_DEAD_DRAG_DELAY if dying else HOOK_FLY_TIME)
		tt.tween_property(target, "position", dest, HOOK_DEAD_DRAG_TIME if dying else HOOK_DRAG_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
