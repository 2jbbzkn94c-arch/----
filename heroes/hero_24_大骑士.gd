extends HeroBase
## 大骑士：你的移动改为沿直线方向冲锋任意距离，然后攻击力上升等量于本次移动距离，直到回合结束。
## 冲锋的**可达格 / 路径 / 加成结算**全部在本脚本里实现（Battle 只调用 uses_charge_movement 系列钩子）。
class_name HeroCharger

## 6 个轴向方向（平顶 odd-q 六边形）
const _DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]
## 冲锋的单次最大格数（不封顶，但设安全上限避免死循环）
const _MAX_CHARGE := 60
## 出生时对移动力的冲锋近似加成（仅用于卡面/AI 估值，实际移动由直线冲锋决定）
const _CHARGE_MOVE_BONUS := 6

func on_spawn() -> void:
	# 冲锋任意距离（近似大幅提升移动力）；冲锋加成/直线在移动逻辑中结算
	unit.move_range += _CHARGE_MOVE_BONUS

## 冲锋是**移动方式**，不是可被沉默的技能：
## 沉默只让"攻击力上升"失效（见 on_charge_settled），直线冲锋照旧可以冲任意距离。
## 只有眩晕/荆棘这类"根本不能移动"的状态才拦住冲锋。
func uses_charge_movement() -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	return unit.can_move()

## 卡面"移动"一直按 ∞ 展示（冲锋不随沉默失效）
func shows_infinite_move() -> bool:
	return uses_charge_movement()

## 可达格：沿 6 个轴向直线逐格推进，撞到单位/障碍/墓碑即停（移动力不封顶）
func charge_reachable_cells() -> Dictionary:
	var out: Dictionary = {}
	var base: Vector2i = battle.grid.axial_of(unit.cell)
	for d in _DIRS:
		var ax: Vector2i = base + d
		while true:
			var off: Vector2i = battle.grid.offset_of(ax)
			if not battle.grid.in_bounds(off):
				break
			if battle.occupancy.has(off) or battle.obstacles.has(off) or battle.graves.has(off):
				break
			out[off] = true
			ax += d
	return out

## 冲锋路径：逐格检查阻挡，途中遇障碍/墓碑/其他单位即停在阻挡前
## （玩家 UI 的可达格本就挡墙，这里兜底 AI/联机指令误算穿墙）
func charge_path(target: Vector2i) -> Array:
	var path: Array = []
	for c in _charge_line_to(target):
		if battle.occupancy.has(c) or battle.obstacles.has(c) or battle.graves.has(c):
			break
		path.append(c)
		if c == target:
			break
	return path

func charge_step_cap() -> int:
	return _MAX_CHARGE

## 冲锋落定：按"实际冲到的格数"写回攻击力上升量（被阻挡剪裁时用实际格数，避免虚高）。
## 被沉默/眩晕时"攻击力上升"这部分技能失效 -> 加成记 0（移动照常，回血类的移动距离照常记）。
func on_charge_settled(actual_steps: int) -> void:
	unit.last_move_dist = actual_steps
	unit.ramble_bonus = actual_steps if unit.skill_allowed() else 0
	unit.refresh_stats()

## 从当前格沿某轴向直线逐格直到 to 的直线格；to 不在任何直线上时退化为 [to]
func _charge_line_to(to: Vector2i) -> Array:
	var base: Vector2i = battle.grid.axial_of(unit.cell)
	var ta: Vector2i = battle.grid.axial_of(to)
	for d in _DIRS:
		var line: Array = []
		var cur: Vector2i = base
		for i in range(_MAX_CHARGE):
			cur += d
			var off: Vector2i = battle.grid.offset_of(cur)
			if not battle.grid.in_bounds(off):
				break
			line.append(off)
			if cur == ta:
				return line
	return [to]
