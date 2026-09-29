extends HeroBase
## 暗域：攻击时和对象交换位置。目标被打死时，占据其空出的格子。
class_name HeroDarkrealm

func on_attack(target: Unit) -> void:
	fx()
	fx_on_target(target)
	if target and target.alive:
		battle._swap_units(unit, target)

## 攻击会与目标交换位置：不做"前冲再弹回"的出招动画（否则与换位演出打架）
func skips_lunge_anim() -> bool:
	return true

## 【2026-09-30·与血锁同一处（见 `HeroBase.melee_has_displace_fx`）】暗域**每一击都有位移演出**：
##   目标活着 ⇒ `_swap_units()` 换位；目标被打死 ⇒ `on_attack_dead()` → `_occupy_dead_cell()` 占尸格。
##   所以这里恒为 true ⇒ Battle 不再给暗域补"原地刀光"（换位那一下已经有戏了）。
func melee_has_displace_fx(target: Unit) -> bool:
	return target != null and is_instance_valid(target)

## 【2026-09-23 新增·用户实机反馈「换位动画结束，反击就来了」】结算后有 0.2s 换位演出
##   （= `Battle._swap_units()` 里那个位移 tween 的时长）⇒ 反击要等它放完再加标准停顿，
##   否则反击会在换位还剩 0.05s 时就起手、正好"贴"着换位结束落地。
func attack_settle_delay() -> float:
	return 0.2

func on_attack_dead(target: Unit) -> void:
	if target and not target.alive:
		battle._occupy_dead_cell(unit, target)
