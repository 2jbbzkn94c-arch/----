class_name BoardView
extends Node2D
## 棋盘渲染层：绘制六边形格子、支持高亮（移动/攻击范围/选中）。
## 输入处理由 Battle 统一完成（使用全局鼠标坐标回查格子）。

var grid: HexGrid
var board_origin := Vector2.ZERO
var _highlights: Dictionary = {}  # cell -> Color
var bombs: Dictionary = {}        # cell -> true（炸弹人的陷阱）
var obstacles: Dictionary = {}     # cell -> 耐久（障碍物）
var buff_items: Dictionary = {}    # cell -> "atk"/"move"（增益道具）
var graves: Dictionary = {}        # cell -> hero_id（阵亡墓碑：替补可选择在此落位）
var _cell_fill := Color(0.12, 0.14, 0.2, 0.86)   # 较实底色，避免透出灰木导致棋子/文字看不清
var _cell_line := Color(0.35, 0.4, 0.5, 0.55)
var _side_zone_player := Color(0.10, 0.2, 0.35, 0.8)
var _side_zone_enemy := Color(0.30, 0.12, 0.12, 0.75)
# 敌方出生区完整格列表（顶帽行+第一满行）；非空时用于底色上色（整片统一）
var enemy_zone_cells: Array = []

func _init(g: HexGrid, origin: Vector2 = Vector2.ZERO) -> void:
	grid = g
	board_origin = origin

func _ready() -> void:
	z_index = 1
	queue_redraw()

func _draw() -> void:
	if grid == null:
		return
	for cell in grid.all_cells():
		var center := board_origin + grid.cell_to_world(cell)
		var color := _cell_fill
		if _highlights.has(cell):
			color = _highlights[cell]
		elif cell.y == grid.height - 1:
			color = _side_zone_player   # 玩家侧（下方）
		elif enemy_zone_cells.has(cell):
			color = _side_zone_enemy    # 敌方出生区整片（顶帽行+第一满行）统一上色
		elif cell.y == 0:
			color = _side_zone_enemy    # 兜底：顶帽行其余（正常情况下已被上面覆盖）
		_draw_hex(center, grid.hex_size * 0.95, color, _cell_line)
	# 炸弹标记
	for cell in bombs.keys():
		var center := board_origin + grid.cell_to_world(cell)
		draw_circle(center, grid.hex_size * 0.32, Color(0.15, 0.15, 0.17, 1.0))
		draw_circle(center, grid.hex_size * 0.18, Color(1.0, 0.55, 0.2, 1.0))
		draw_arc(center, grid.hex_size * 0.4, 0, TAU, 16, Color(1.0, 0.4, 0.2, 0.9), 2.0)
	# 障碍物（灰色岩石）
	for cell in obstacles.keys():
		var center := board_origin + grid.cell_to_world(cell)
		_draw_hex(center, grid.hex_size * 0.78, Color(0.35, 0.33, 0.30, 1.0), Color(0.55, 0.52, 0.48, 1.0))
		draw_arc(center, grid.hex_size * 0.5, -1.2, 1.2, 10, Color(0.6, 0.58, 0.5, 0.9), 2.0)
		# 剩余血量
		var hpv: int = obstacles[cell]
		var hp_col := Color(1.0, 0.5, 0.35) if hpv <= 1 else Color(1.0, 0.85, 0.55)
		draw_string(ThemeDB.fallback_font, center + Vector2(-8, 6), str(hpv),
			HORIZONTAL_ALIGNMENT_CENTER, 16, 16, hp_col)
	# 增益道具/金矿（各类型颜色区分）
	for cell in buff_items.keys():
		var center := board_origin + grid.cell_to_world(cell)
		var st: String = buff_items[cell]
		var color := Color(0.85, 0.9, 1.0)
		match st:
			"atk":
				color = Color(1.0, 0.42, 0.32)   # 攻击：红
			"move":
				color = Color(0.5, 0.85, 1.0)    # 移动：蓝
			"heal":
				color = Color(0.42, 0.95, 0.5)   # 回血：绿
			"shield":
				color = Color(0.8, 0.62, 1.0)   # 护盾：淡紫（与金矿的黄色区分开）
			"gold":
				color = Color(1.0, 0.9, 0.15)    # 金矿：亮黄
		draw_circle(center, grid.hex_size * 0.26, Color(0.25, 0.2, 0.08, 0.9))
		draw_circle(center, grid.hex_size * 0.16, color)
	# 墓碑（灰色十字石碣）：替补可选择在其上方/周围落位，落位后消失
	for cell in graves.keys():
		var center := board_origin + grid.cell_to_world(cell)
		var s := grid.hex_size
		# 底座
		draw_rect(Rect2(center + Vector2(-s * 0.24, s * 0.05), Vector2(s * 0.48, s * 0.14)),
			Color(0.28, 0.27, 0.30, 1.0))
		# 碑身（圆顶石碣）
		var stone := Color(0.42, 0.40, 0.44, 1.0)
		draw_rect(Rect2(center + Vector2(-s * 0.17, -s * 0.38), Vector2(s * 0.34, s * 0.43)), stone)
		draw_circle(center + Vector2(0, -s * 0.38), s * 0.17, stone)
		# 十字
		draw_rect(Rect2(center + Vector2(-s * 0.045, -s * 0.3), Vector2(s * 0.09, s * 0.26)),
			Color(0.15, 0.14, 0.16, 1.0))
		draw_rect(Rect2(center + Vector2(-s * 0.14, -s * 0.22), Vector2(s * 0.28, s * 0.09)),
			Color(0.15, 0.14, 0.16, 1.0))

func _draw_hex(center: Vector2, radius: float, fill: Color, line: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)   # flat-top：平边朝上（顶点在 0/60/...°）
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	draw_colored_polygon(pts, fill)
	draw_polyline(_closed(pts), line, 2.0, true)

func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	out.append(pts[0])
	return out

# ---- 高亮控制（调用后需 queue_redraw） ----
func set_highlights(colors: Dictionary) -> void:
	_highlights = colors
	queue_redraw()

func clear_highlights() -> void:
	_highlights.clear()
	queue_redraw()

func cell_world_center(cell: Vector2i) -> Vector2:
	return board_origin + grid.cell_to_world(cell)
