extends HeroBase
## 长剑：攻击敌人时，一并伤害目标身后直线上的所有敌人。
## 目标死亡时剑气仍沿其身后穿透。剑气照样穿过障碍物（不停下），但扫过的障碍各掉 1 点耐久
## ——规则：技能对敌人生效时波及到的障碍要掉耐久；主动攻击障碍物则不触发任何英雄技能。
## 【2026-09-29·用户要求「把长剑的剑气去了，改成普通攻击的刀光飞出去」】本脚本原来自己画一道
##   银蓝月弯（`SwordCrescent` 自绘节点），现在**整块删掉**，改调 `Battle.fly_melee_slash()` ——
##   放出去的就是近战那道**刀光贴图**（`assets/美术资源/近战刀光.png`，尺寸/粗细/亮度/方向与近战共用
##   同一组 `MELEE_SLASH_*` 常量），只是它沿这条直线**飞**出去、到尽头淡出。
class_name HeroSwordline

# 普攻的刀光在 `play_strike_fx()`（出招那一刻）放过一次，置位后由 `on_attack` / `on_attack_dead`
# **消费**掉；于是**反击**（不经过出招动画、没有 `play_strike_fx()`）仍然在那里补一道。
var _strike_slash_sent := false

## 【2026-09-29·用户要求「长剑不要刀光一下、然后刀光飞出去，我要刀光**直接**飞出去」】
##   跳过"原地那道刀光"（`Battle._play_melee_hit()` 里那道）：本英雄放的是**飞**出去的那道
##   （`_fly_slash_toward()` → `Battle.fly_melee_slash()`）⇒ 同一次攻击只该有飞的那一道。
func skips_melee_slash() -> bool:
	return true

## 【2026-09-29·用户报「长剑的突一下和剑气时间上搭配的不好」】刀光改在**出招动作开始那一刻**放
##   （`Battle._play_melee_hit()` 在两段补间之前调本钩子）⇒ 刀光与"突一下"同时起步。
##   原来挂在 `on_attack` 上，那是动作**末尾**（结算伤害时，0.22 秒后）才调 ⇒ 突完了才起飞。
func play_strike_fx(target: Unit) -> void:
	if target == null or not is_instance_valid(target):
		return
	_strike_slash_sent = true
	_fly_slash_toward(target.cell)

func on_attack(target: Unit) -> void:
	_fly_slash_if_not_sent(target)
	if target and target.alive:
		battle._pierce_back(unit, target)

func on_attack_dead(target: Unit) -> void:
	_fly_slash_if_not_sent(target)
	if target and not target.alive:
		battle._pierce_line(unit, target.cell)

func _fly_slash_if_not_sent(target: Unit) -> void:
	if _strike_slash_sent:
		_strike_slash_sent = false
		return
	if target == null or not is_instance_valid(target):
		return
	_fly_slash_toward(target.cell)

# 【2026-09-29·用户报「长剑的突一下和剑气时间上搭配的不好」】飞出去这道刀光原来用
#   `clampf(距离 * 0.022, 0.55, 1.2)` —— 一格就远超 55 像素 ⇒ **任何真实距离都顶到 1.2 秒**，
#   而伤害在出招后 0.22 秒就结算了（前压 0.12 + 回位 0.1，见 `Battle._play_melee_hit()`）⇒
#   掉完血刀光还在半路爬。现在时长按"出招那一拍"给。
#   【同日第二版·用户实机「长剑的剑气飞出去太快了」】0.24 → **0.55**：刀光与"突一下"同时起步
#   （见 `play_strike_fx()`，这一条是重点），但**飞得比突进慢** —— 0.22 秒结算伤害时它大约
#   飞到连线的**一半**（`fly_melee_slash()` 里是 QUAD/EASE_OUT：先快后慢），再顺势把整条线
#   扫完淡出。
#   【2026-09-30·用户口径「长剑的刀光飞行速度太快」】0.55 → **0.85** →（同日「再慢点」）**1.2**：
#   整段 ≈ 0.06（亮度升起）+ 1.2 + 0.16（尾巴淡出）≈ **1.42 秒**；0.22 秒结算伤害时它大约飞到
#   连线的**三成半**（≈35%）。⚠️ 这段演出是"发出去了就不管"（`fly_melee_slash()` 不等它）⇒
#   拖长**不会**拖慢出手/回合节奏，只是它在屏幕上留得久一点。
#   **嫌快嫌慢只改这一个数（大 = 飞得慢）**；想更"匀速"（不要起步那一冲）的话改
#   `Battle.MeleeSlash._update()` 里那句缓动（QUAD/EASE_OUT → LINEAR）。
const SLASH_FLIGHT_DUR := 1.2

# 刀光演出：从长剑沿目标方向**飞到直线尽头**再消失
func _fly_slash_toward(target_cell: Vector2i) -> void:
	var g: HexGrid = battle.grid
	var bv: BoardView = battle.board_view
	var a: Vector2i = g.axial_of(unit.cell)
	var t: Vector2i = g.axial_of(target_cell)
	var step: Vector2i = t - a
	if step == Vector2i.ZERO:
		return
	var start: Vector2 = bv.cell_world_center(unit.cell)
	var end: Vector2 = bv.cell_world_center(g.offset_of(a + step * 8))
	battle.fly_melee_slash(start, end, SLASH_FLIGHT_DUR)
