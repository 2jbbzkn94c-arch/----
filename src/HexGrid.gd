class_name HexGrid
extends RefCounted
## 六边形网格逻辑层（与渲染解耦）。
## 采用轴对齐偏移坐标系（odd-q，平顶布局、列间错位），形状为 宽 x 高 的矩形棋盘。
## 邻居与距离全部通过轴向坐标计算，避免偏移坐标到处写奇偶判断。

# 轴向邻居偏移（flat-top 平顶与 pointy-top 尖顶共用的轴向邻居集合）
const AXIAL_NEIGHBORS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, -1), Vector2i(-1, 1),
]

var width := 6   # 列数
var height := 5  # 行数
var hex_size := 48.0  # 六边形外接半径（像素）
# 顶部"顶帽"：第 0 行只保留 top_cap_cols 指定的列（空表示无顶帽，满行矩形）
var top_cap_cols: Array[int] = []

# 视角翻转（联机访客）：true 时把整个棋盘绕中心旋转 180°，让"我方阵营"落在屏幕下方。
# 只影响 cell<->像素 的映射（渲染 + 鼠标命中回查），不改变任何逻辑格坐标/阵营归属/距离判定。
var view_flip := false
var _flip_center := Vector2.ZERO
var _flip_center_ready := false

func _init(w: int = 6, h: int = 5, size: float = 48.0) -> void:
	width = w
	height = h
	hex_size = size

func in_bounds(cell: Vector2i) -> bool:
	if cell.y < 0 or cell.y >= height:
		return false
	if cell.y == 0 and top_cap_cols.size() > 0:
		return cell.x in top_cap_cols
	return cell.x >= 0 and cell.x < width

# 返回棋盘上所有合法格子
func all_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in height:
		for c in width:
			var cell := Vector2i(c, r)
			if in_bounds(cell):
				out.append(cell)
	return out

# 公开的轴向坐标转换（用于直线/距离等判定）
func axial_of(c: Vector2i) -> Vector2i:
	return _offset_to_axial(c)

func offset_of(a: Vector2i) -> Vector2i:
	return _axial_to_offset(a)

func _offset_to_axial(c: Vector2i) -> Vector2i:
	# odd-q（奇数列下移）-> 轴向
	var half := int((c.x - (c.x % 2)) / 2.0)
	return Vector2i(c.x, c.y - half)

func _axial_to_offset(a: Vector2i) -> Vector2i:
	# odd-q 逆变换
	var half := int((a.x - (a.x % 2)) / 2.0)
	return Vector2i(a.x, a.y + half)

# 返回某格的所有合法在界邻居（轴向计算）
func neighbors(cell: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var axial := _offset_to_axial(cell)
	for n in AXIAL_NEIGHBORS:
		var off := _axial_to_offset(axial + n)
		if in_bounds(off):
			result.append(off)
	return result

# 两格之间的六边形距离（轴向曼哈顿）
func distance(a: Vector2i, b: Vector2i) -> int:
	var ra := _offset_to_axial(a)
	var rb := _offset_to_axial(b)
	# 【2026-10-03】这里 `/ 2` 是**故意的整数除**（六边形立方距离的分子恒为偶数）⇒ 用注解声明：
	#   `/ 2.0` 再转回 int 会在热路径上白付一次浮点转换（与 `Menu.gd` / `DataRegistry.gd` 同一写法）。
	@warning_ignore("integer_division")
	return (abs(ra.x - rb.x) + abs(ra.x + ra.y - rb.x - rb.y) + abs(ra.y - rb.y)) / 2

# 单位像素位置（flat-top 平顶，odd-q 列错位）：奇数列下移半格
func cell_to_world(c: Vector2i) -> Vector2:
	var p := _raw_cell_to_world(c)
	if view_flip:
		p = _flip_point(p)
	return p

# 世界中某点反查最近格子（用于点击）
func world_to_cell(pos: Vector2) -> Vector2i:
	if view_flip:
		pos = _flip_point(pos)
	# 近似：遍历所有合法格取最近（棋盘极小，足够）
	var best := Vector2i(0, 0)
	var best_d := INF
	var cells := all_cells()
	for cell in cells:
		var p := _raw_cell_to_world(cell)
		var d := p.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = cell
	# 距最近格中心超过六边形外接半径 -> 点击棋盘外，返回哨兵格（外面无任何合法格）
	if best_d > hex_size * hex_size:
		return Vector2i(-99, -99)
	return best

# 未翻转的原始像素坐标
func _raw_cell_to_world(c: Vector2i) -> Vector2:
	var x := hex_size * 1.5 * float(c.x)
	var y := hex_size * sqrt(3.0) * (c.y + 0.5 * float(c.x & 1))
	return Vector2(x, y)

# 绕棋盘像素中心做 180° 点反射（翻转 view）。中心 = 所有格未翻转像素包围盒的中点。
func _flip_point(p: Vector2) -> Vector2:
	_ensure_flip_center()
	return _flip_center * 2.0 - p

func _ensure_flip_center() -> void:
	if _flip_center_ready:
		return
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for cell in all_cells():
		var pp := _raw_cell_to_world(cell)
		minx = min(minx, pp.x)
		miny = min(miny, pp.y)
		maxx = max(maxx, pp.x)
		maxy = max(maxy, pp.y)
	_flip_center = Vector2((minx + maxx) / 2.0, (miny + maxy) / 2.0)
	_flip_center_ready = true

# 翻转中心（供渲染/测试用；懒计算，未翻转时同样可用）
func flip_center() -> Vector2:
	_ensure_flip_center()
	return _flip_center

# 攻击视线：返回 from 到 to 的中间格（不含两端）——仅同轴直线（dq0/dr0/dq=-dr）。
# 保留给旧调用/测试；新视线判定统一用 los_blocked（支持斜向多路最短径）。
func los_mid_cells(from: Vector2i, to: Vector2i) -> Array:
	var out: Array = []
	if from == to:
		return out
	var fa := _offset_to_axial(from)
	var ta := _offset_to_axial(to)
	var dq := ta.x - fa.x
	var dr := ta.y - fa.y
	if dq != 0 and dr != 0 and dq != -dr:
		return out   # 斜向目标：中间格有歧义，不按单一格判阻挡
	var cube_a := Vector3(float(fa.x), float(fa.y), -float(fa.x + fa.y))
	var cube_b := Vector3(float(ta.x), float(ta.y), -float(ta.x + ta.y))
	var n := distance(from, to)
	if n <= 1:
		return out
	for i in range(1, n):
		var t := float(i) / float(n)
		var cx := cube_a.x + (cube_b.x - cube_a.x) * t
		var cy := cube_a.y + (cube_b.y - cube_a.y) * t
		var cz := cube_a.z + (cube_b.z - cube_a.z) * t
		var rc := _cube_round(cx, cy, cz)
		out.append(_axial_to_offset(Vector2i(int(rc.x), int(rc.y))))
	return out

# 视线是否被挡：**是否存在一条"从 from 到 to 的最短路径"，其所有中间格都未被阻挡**。
# 同轴直线只有唯一一条路（中间任一格被挡即挡）；斜向有多条最短径，只要还留一条全程畅通就能打。
# is_blocked(cell) 判定该格是否被单位/障碍/墓碑占据。
func los_blocked(from: Vector2i, to: Vector2i, is_blocked: Callable) -> bool:
	if from == to:
		return false
	var d := distance(from, to)
	if d <= 1:
		return false
	# 所有"位于某条最短径上"的中间格
	var cand: Dictionary = {}
	for c in all_cells():
		if c == from or c == to:
			continue
		if distance(from, c) + distance(c, to) == d:
			cand[c] = true
	# BFS：只允许经过"未被阻挡的候选中间格"（端点自由），能到 to 即可打
	var reach := {from: true}
	var frontier: Array = [from]
	while frontier.size() > 0:
		var cur: Vector2i = frontier.pop_front()
		if cur == to:
			return false   # 打通了
		for n in neighbors(cur):
			if reach.has(n):
				continue
			if n == to:
				reach[to] = true
				frontier.append(n)
				continue
			if not cand.has(n):
				continue
			if is_blocked.call(n):
				continue
			reach[n] = true
			frontier.append(n)
	return true   # 所有最短路都被堵死

# 把浮点 cube 坐标四舍五入到最近的合法 cube（三坐标和为 0）
func _cube_round(x: float, y: float, z: float) -> Vector3:
	var rx: float = round(x)
	var ry: float = round(y)
	var rz: float = round(z)
	var dx: float = absf(rx - x)
	var dy: float = absf(ry - y)
	var dz: float = absf(rz - z)
	if dx >= dy and dx >= dz:
		rx = -ry - rz
	elif dy >= dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector3(rx, ry, rz)

# 返回从 start 出发、步数 <= move_range 的**可停靠**格子集合。
# stop_forbidden: 不可停靠的格子（例如被单位占据），但仍可作为"通行"中转。
# path_blockers: 阻挡通行的格子（无法穿过），例如普通单位视所有单位均为阻挡。
# 若某个格子在 path_blockers 中则无法进入（断开路径）；若只在 stop_forbidden 中则
# 可通行但不可停靠（用于"渗透"：穿越敌方但不落脚）。
func reachable(start: Vector2i, move_range: int, stop_forbidden: Dictionary, path_blockers: Dictionary = {}) -> Dictionary:
	var visited := {start: true}
	var frontier := [start]
	var dist := {start: 0}
	var stoppable := {}
	while frontier.size() > 0:
		var cur: Vector2i = frontier.pop_front()
		var d: int = dist[cur]
		if d >= move_range:
			continue
		for n in neighbors(cur):
			if visited.has(n):
				continue
			if path_blockers.has(n) and n != start:
				continue
			visited[n] = true
			dist[n] = d + 1
			frontier.append(n)
			if not stop_forbidden.has(n) and n != start:
				stoppable[n] = true
	return stoppable

# BFS 寻路：返回从 start 到 goal 的格子路径（不含 start，含 goal）。
# blockers 中的格子无法进入（start 除外）；不可达或 start==goal 时返回 [goal]。
func find_path(start: Vector2i, goal: Vector2i, blockers: Dictionary = {}) -> Array:
	if start == goal:
		return [goal]
	var visited := {start: true}
	var parent := {start: Vector2i(-99, -99)}
	var frontier := [start]
	while frontier.size() > 0:
		var cur: Vector2i = frontier.pop_front()
		if cur == goal:
			break
		for n in neighbors(cur):
			if visited.has(n):
				continue
			if blockers.has(n) and n != start:
				continue
			visited[n] = true
			parent[n] = cur
			frontier.append(n)
	if not visited.has(goal):
		return [goal]
	var path: Array = [goal]
	var curv: Vector2i = goal
	while curv != start:
		curv = parent[curv]
		path.push_front(curv)
	path.pop_front()
	return path
