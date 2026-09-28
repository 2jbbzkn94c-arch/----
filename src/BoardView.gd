class_name BoardView
extends Node2D
## 棋盘渲染层：绘制六边形格子、支持高亮（移动/攻击范围/选中）。
## 输入处理由 Battle 统一完成（使用全局鼠标坐标回查格子）。

var grid: HexGrid
var board_origin := Vector2.ZERO
var _highlights: Dictionary = {}  # cell -> Color
var occupied_cells: Dictionary = {}  # cell -> true：有棋子的格（出生区色罩不在这些格上画，见 `_cell_tint`）
# 【2026-09-28·用户报「录像的部署段，部署英雄的格子蓝色底色会更深一点」】出生区色罩的**专用通道**：
#   实机部署走 `Battle._preview_cells`（高亮），而回放里 `_apply_highlights()` 会把高亮强制清空 ⇒ 回放照着
#   `deploy_zone` 这条独立通道铺罩（见 `Battle._show_replay_deploy_zone()`），并且**有棋子的格不铺**
#   ⇒ 部署段整片出生区是同一种蓝，站着英雄的格子不会再多出一层。
var deploy_zone: Dictionary = {}     # cell -> Color
# 墓碑阵营底色开关（【2026-09-28】只在替补/落位阶段亮，见 `GRAVE_BG_*` 的说明）
var show_grave_faction := false
var bombs: Dictionary = {}        # cell -> true（炸弹人的陷阱）
var obstacles: Dictionary = {}     # cell -> 耐久（障碍物）
var buff_items: Dictionary = {}    # cell -> "atk"/"move"（增益道具）
# 【2026-09-21 用户定稿·圣诞老人】道具归属：cell -> 阵营（-1/缺省 = 中立，双方都能捡）。
# 画面上用一圈描边区分：我方（PLAYER）绿、敌方（ENEMY）红 ⇒ 一眼看出"这枚是谁的礼物"。
var buff_owner: Dictionary = {}
# 【2026-09-21 用户定稿·圣诞老人】演出用：这些格子上的道具**暂不画**（礼物还在空中飞，
# 落地后由 Battle 从本表里移除 ⇒ 图标才出现）。只影响绘制，不影响 buff_items 逻辑。
var hidden_item_cells: Dictionary = {}
var gold_left: Dictionary = {}     # cell -> 金矿剩余回合数（右下角小字展示，3→0消失）
var graves: Dictionary = {}        # cell -> hero_id（阵亡墓碑：替补可选择在此落位）
var _cell_fill := Color(0.12, 0.14, 0.2, 0.86)   # 兜底底色（木纹贴图缺失时才用）
var _cell_line := Color(0, 0, 0, 0.85)   # 六边形格线：黑色，清楚显示格子边界
# 【已删 2026-09-19（用户同意）】原 `_side_zone_player` / `_side_zone_enemy` 两个颜色常量：
#   木纹贴图上线后，出生区改用下面的"半透明色罩"（`_zone_player_overlay` / `_zone_enemy_overlay`），
#   这两个旧常量在全项目**再无任何引用** ⇒ Godot 启动时报 `UNUSED_PRIVATE_CLASS_VARIABLE`
#   （`BoardView.gd:16`）⇒ 直接删掉，控制台恢复干净。
# 木纹贴上后，出生区/高亮改成"半透明色罩"盖在木纹上（否则会把木纹整块盖住看不见）
var _zone_player_overlay := Color(0.10, 0.45, 0.85, 0.42)
var _zone_enemy_overlay := Color(0.85, 0.2, 0.18, 0.38)
# 敌方出生区完整格列表（顶帽行+第一满行）；非空时用于底色上色（整片统一）
var enemy_zone_cells: Array = []
# 金矿美术素材（2026-09-14 用户提供；已做：去白底透明化、擦掉左上角水印、裁到图案边界）
const GOLD_TEX := preload("res://assets/美术资源/金矿.png")
# 障碍物素材（2026-09-14 用户提供酒桶图；已去白底、去右下角水印、裁到桶身边界）
const OBSTACLE_TEX := preload("res://assets/美术资源/障碍.png")
# 墓碑素材（2026-09-25 用户提供 R.I.P. 石碣图；处理见 tools/处理墓碑贴图.ps1：
#   去白底透明化、裁到碑身边界、**右下角水印被裁框排除**）
const GRAVE_TEX := preload("res://assets/美术资源/墓碑.png")
# 墓碑尺寸：碑高 = 格高 × 这个系数（与酒桶 OBSTACLE_H 同口径：正好落在六边形格子里、不压相邻格）。
# 想更大/更小就改这一个数（宽度按原图比例自动算，不会拉伸变形）。
# ⚠️ 2026-09-25 换成"带花与土"的版本后从 0.60 调到 **0.66**：新图比旧图矮胖
#   （含花与土 283×298，碑身只占上面 ~85%）⇒ 0.66 让碑身看起来和上一版差不多大。
const GRAVE_H := 0.66
# 【2026-09-28·用户要求】「给墓碑增加背景，哪方的就显示什么颜色」：碑下铺一格**半透明阵营色**六边形
#   （我方蓝 / 敌方红，与棋子阵营底色同一组色；灰度石碑压在上面 ⇒ 一眼看出这块碑归谁）。
#   【同日第二/三次口径】「底色太亮了，而且不要有蓝色边框」⇒ alpha `0.55 → 0.30`、**去掉那圈描边**；
#   「替补的时候才亮的色」⇒ 平时**不画**，只有替补/落位阶段（`SUBSTITUTING` / `PLACE_SUB`）才亮 ——
#   由 `Battle._process()` 推 `set_grave_faction(on)`（那时墓碑正是可选落点，标出归属才有意义）。
#   要更淡/更浓只改这两个 alpha（`0.2` 很淡 / `0.5` 偏亮）。
const GRAVE_BG_PLAYER := Color(0.25, 0.55, 0.9, 0.30)
const GRAVE_BG_ENEMY := Color(0.85, 0.32, 0.28, 0.30)
# 「增益道具 / 金矿」图标的方框边长 = 六边形外接半径 × 这个系数（贴图按原比例放进方框、居中）。
const ITEM_ICON_BOX := 0.75
# 【2026-09-25 用户要求「将金矿大小变大」】金矿单独用更大的方框：0.75 → **1.05**
#   ⇒ r=60 的格子上边长 45px → **63px**（金矿图 137×129 ≈ 方形 ⇒ 约 63×59px）。
#   上限参考：flat-top 六边形 r=60 时，中心能完整放下 ~73px 的方图（角点在内切圆内）⇒ 63px 还留了余量。
#   ⚠️ 金矿右下角那串"剩余回合数"用的是 `_digit_anchor()`（中心 +0.3r,+0.7r）⇒ 图标变大后数字仍画在
#     图标下缘外侧；若你觉得挤，改 `_digit_anchor()` 的第二个分量即可。
const GOLD_ICON_BOX := 1.05
# 道具素材：圣盾=用户提供的盾牌图；攻击/回血/移动用已有图案或用户提供的图
# （都去了白底、裁到图案边界；见 tools/处理地块贴图.gd）
const SHIELD_TEX := preload("res://assets/美术资源/圣盾.png")
const ITEM_ATK_TEX := preload("res://assets/美术资源/道具攻击.png")
const ITEM_HEAL_TEX := preload("res://assets/美术资源/道具爱心.png")
const ITEM_MOVE_TEX := preload("res://assets/美术资源/道具移动.png")
# 酒桶尺寸：桶高 = 格高 × 这个系数。0.78 左右桶正好整个落在六边形格子里（不会压到相邻格）；
# 想更大/更小就改这一个数。
const OBSTACLE_H := 0.60
# 地块木纹（2026-09-14 用户提供两张：干净木板 / 带血污木板）。
# 处理过：去奶白底透明化、六边形遮罩裁掉四角水印、裁到图案边界、**旋转 90°**——
# 用户原图是"顶点朝上"的六边形，而棋盘是"平边朝上"，不转过来边角对不上。
const TILE_TEXS: Array = [
	preload("res://assets/美术资源/地块木板1.png"),
	preload("res://assets/美术资源/地块木板2.png"),
]
# 木纹压暗（乘法着色）：原图是很亮的橙木，直接铺会晃眼、也压过棋子。
# 想更暗/更亮就改这里：三个分量越小越暗；让 R 略小于 G/B 可以顺带降一点饱和。
const TILE_TINT := Color(0.76, 0.80, 0.80)
# cell -> 用第几张木纹。开局按 tile_seed 随机铺一次（联机两端同种子，铺法一致）。
var tile_pick: Dictionary = {}
var tile_seed := 0

# 出生区色罩是否显示：**只在部署英雄时**亮（开局选人/放位阶段由 Battle 打开，部署完就关）
var show_spawn_zones := false
# 格子绘制半径系数：1.0 = 相邻格严丝合缝（间隙 0）。
# 相邻六边形中心距 = √3 × hex_size，各自画到 hex_size 半径时正好在外接处贴合，不再露底色缝。
# 想要一条细缝（看起来更像瓷砖）就调小一点，比如 0.985。
const CELL_R := 1.0

func _init(g: HexGrid, origin: Vector2 = Vector2.ZERO) -> void:
	grid = g
	board_origin = origin

func _ready() -> void:
	z_index = 1
	_rebuild_tiles()
	queue_redraw()

# 按 tile_seed 随机给每格挑一张木纹。格子顺序来自 grid.all_cells()，两端一致。
func _rebuild_tiles() -> void:
	tile_pick.clear()
	if grid == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = tile_seed
	for cell in grid.all_cells():
		tile_pick[cell] = rng.randi() % TILE_TEXS.size()
	queue_redraw()

# 外部（Battle）在开局时给一个种子：联机用同一颗种子 → 两端木纹位置一致；单机每局随机
func set_tile_seed(s: int) -> void:
	tile_seed = s
	_rebuild_tiles()

func _draw() -> void:
	if grid == null:
		return
	for cell in grid.all_cells():
		var center := board_origin + grid.cell_to_world(cell)
		_draw_cell_tile(cell, center)          # 木纹底（两张图随机铺）
		var tint: Variant = _cell_tint(cell)
		if tint != null:
			_draw_hex_fill(center, grid.hex_size * CELL_R, tint)   # 出生区/高亮：半透明色罩
		_draw_hex_outline(center, grid.hex_size * CELL_R, _cell_line)
	# 炸弹标记
	for cell in bombs.keys():
		var center := board_origin + grid.cell_to_world(cell)
		draw_circle(center, grid.hex_size * 0.32, Color(0.15, 0.15, 0.17, 1.0))
		draw_circle(center, grid.hex_size * 0.18, Color(1.0, 0.55, 0.2, 1.0))
		draw_arc(center, grid.hex_size * 0.4, 0, TAU, 16, Color(1.0, 0.4, 0.2, 0.9), 2.0)
	# 障碍物：酒桶素材。桶比格子窄高，按"桶高 = 格高 × OBSTACLE_H"等比放入格中（不拉伸变形）
	for cell in obstacles.keys():
		var center := board_origin + grid.cell_to_world(cell)
		var cell_h := grid.hex_size * sqrt(3.0) * CELL_R
		var bh := cell_h * OBSTACLE_H
		var bw := bh * float(OBSTACLE_TEX.get_width()) / float(OBSTACLE_TEX.get_height())
		draw_texture_rect(OBSTACLE_TEX, Rect2(center - Vector2(bw, bh) * 0.5, Vector2(bw, bh)), false)
		# 剩余耐久：数字画在格子右下角（黑色、大字号，见 _draw_cell_digit）
		_draw_cell_digit(center, str(int(obstacles[cell])))
	# 增益道具/金矿（有美术素材的直接贴图；移动道具仍用程序画的蓝点）
	for cell in buff_items.keys():
		if hidden_item_cells.has(cell):
			continue   # 【圣诞老人】礼物还在飞：这一格先不画（落地后 Battle 解除隐藏）
		var center := board_origin + grid.cell_to_world(cell)
		var st: String = buff_items[cell]
		var tex: Texture2D = null
		match st:
			"atk":
				tex = ITEM_ATK_TEX      # 攻击力：已有的攻击图案
			"heal":
				tex = ITEM_HEAL_TEX     # 回血：已有的爱心图案
			"move":
				tex = ITEM_MOVE_TEX     # 移动力：用户提供的翅膀图
			"shield":
				tex = SHIELD_TEX        # 圣盾：用户提供的盾牌图
			"gold":
				tex = GOLD_TEX          # 金矿：已有的金矿素材
		if tex != null:
			# 【2026-09-25 用户要求「将金矿大小变大」】金矿单独放大（其余道具维持原尺寸）。
			#   方框边长 = 六边形外接半径 × 系数（`GOLD_ICON_BOX` / `ITEM_ICON_BOX`），贴图按原比例放进方框。
			_draw_cell_icon(tex, center,
				grid.hex_size * (GOLD_ICON_BOX if st == "gold" else ITEM_ICON_BOX))
		else:
			# 防御：将来新增道具类型没配贴图时，画个黄点提示，别整格空着
			draw_circle(center, grid.hex_size * 0.26, Color(0.25, 0.2, 0.08, 0.9))
			draw_circle(center, grid.hex_size * 0.16, Color(1.0, 0.9, 0.3))
		# 【2026-09-21 用户定稿·圣诞老人】归属标记：**右下角一个小圆点**（我方蓝 / 敌方红），
		#   位置与"金矿剩余回合数/障碍耐久"的数字锚点同一套（`_digit_anchor` = 格右下），
		#   只是往上挪一点、别和数字打架；中立道具（无归属）不画点。
		#   （第一版画的是"整格描边圈"，用户要求改成右下角圆点 —— 描边太抢眼、和圣盾等特效混在一起。）
		if buff_owner.has(cell):
			var own := int(buff_owner[cell])
			var dot := Color(0.35, 0.62, 1.0, 1.0) if own == DataRegistry.Faction.PLAYER else Color(1.0, 0.33, 0.3, 1.0)
			var dp := _digit_anchor(center)   # 与"金矿剩余回合数/障碍耐久"同一套右下角锚点
			draw_circle(dp, grid.hex_size * 0.17, Color(0, 0, 0, 0.85))   # 黑底：保证在任何贴图上都看得清
			draw_circle(dp, grid.hex_size * 0.12, dot)
		# 金矿：右下角显示剩余回合数（3→2→1，到0消失），与障碍耐久同一套画法
		if st == "gold" and gold_left.has(cell):
			_draw_cell_digit(center, str(int(gold_left[cell])))
	# 墓碑（R.I.P. 石碣素材，2026-09-25 用户提供）：替补可选择在其上方/周围落位，落位后消失
	#   ⚠️ 2026-09-25 用户要求「将墓碑替换成这个」⇒ 由**代码画**（底座 + 圆顶 + 十字，灰色）改成贴图。
	#   尺寸口径与酒桶一致：碑高 = 格高 × `GRAVE_H`、宽按原图比例 ⇒ 不会拉伸变形。
	for cell in graves.keys():
		var center := board_origin + grid.cell_to_world(cell)
		var cell_h := grid.hex_size * sqrt(3.0) * CELL_R
		var gh := cell_h * GRAVE_H
		var gw := gh * float(GRAVE_TEX.get_width()) / float(GRAVE_TEX.get_height())
		# 【2026-09-28·用户要求】碑的底色 = 阵亡者所属阵营（我方蓝 / 敌方红）：
		#   `graves[cell]` 现在是 { "hero": hero_id, "fn": 阵营 }；**旧格式**（只存 hero_id 的旧录像）分不清阵营
		#   ⇒ 退回按敌方红画，别赌成我方。底色先铺、贴图后压 ⇒ 灰碑依旧清楚；**不描边**（用户口径）。
		#   且**只在替补/落位阶段**才铺（`show_grave_faction`，见上面常量说明）—— 平时碑就是一块灰石头。
		#   ⚠️ 【2026-09-28·用户报「点了替补英雄后墓碑底色变成灰色」】这格**已经有高亮**时就不再铺底色：
		#   落位阶段的本方墓碑格会被 `Battle._on_sub_pick()` 染成阵营色（原来那里是土黄 ⇒ 宝石黄压着蓝底
		#   就显灰）。两层同色叠起来只会发闷 ⇒ 谁在谁不画，保证这一格只有**一层**阵营色。
		if show_grave_faction and not _highlights.has(cell):
			var bg := GRAVE_BG_PLAYER if _grave_faction(cell) == DataRegistry.Faction.PLAYER else GRAVE_BG_ENEMY
			draw_colored_polygon(_hex_points(center, grid.hex_size * CELL_R), bg)
		draw_texture_rect(GRAVE_TEX, Rect2(center - Vector2(gw, gh) * 0.5, Vector2(gw, gh)), false)

# 这块碑属于哪一方：新格式读 `fn`；旧格式（只存 hero_id 的录像）分不清 ⇒ 按敌方（红）
func _grave_faction(cell: Vector2i) -> int:
	var g = graves.get(cell)
	if g is Dictionary:
		return int((g as Dictionary).get("fn", DataRegistry.Faction.ENEMY))
	return DataRegistry.Faction.ENEMY

func _draw_hex(center: Vector2, radius: float, fill: Color, line: Color) -> void:
	var pts := _hex_points(center, radius)
	draw_colored_polygon(pts, fill)
	draw_polyline(_closed(pts), line, 2.0, true)

# 每格的木纹底：贴图本身就是"平边朝上"的六边形外框（宽:高 = 2:√3），按格子六边形等比铺满即可
func _draw_cell_tile(cell: Vector2i, center: Vector2) -> void:
	if TILE_TEXS.size() == 0:
		_draw_hex(center, grid.hex_size * CELL_R, _cell_fill, _cell_line)
		return
	var tex: Texture2D = TILE_TEXS[int(tile_pick.get(cell, 0)) % TILE_TEXS.size()]
	var r := grid.hex_size * CELL_R
	var size := Vector2(r * 2.0, r * sqrt(3.0))
	draw_texture_rect(tex, Rect2(center - size * 0.5, size), false, TILE_TINT)

# 该格要不要再盖一层色罩：高亮 > （仅部署阶段）出生区；都不需要时返回 null（纯木纹）
# 【2026-09-28·用户报「部署阶段，英雄的蓝色底色和出生区有重叠」】**有棋子的格不画出生区色罩**：
#   棋子自己的阵营底色是半透明的 ⇒ 与出生区那层蓝/红叠在一起成了"双层蓝"，看着像重叠成一块。
#   占用表由 `Battle._process()` 每帧推（`set_occupied`），只有部署阶段会用到。
func _cell_tint(cell: Vector2i) -> Variant:
	if _highlights.has(cell):
		return _highlights[cell]
	if deploy_zone.has(cell) and not occupied_cells.has(cell):
		return deploy_zone[cell]   # 回放部署段的出生区（实机那条走高亮通道，见 `deploy_zone` 的说明）
	if show_spawn_zones and not occupied_cells.has(cell):
		if cell.y == grid.height - 1:
			return _zone_player_overlay
		if enemy_zone_cells.has(cell) or cell.y == 0:
			return _zone_enemy_overlay
	return null

# 出生区色罩（回放部署段专用通道；传空字典 = 收掉）。没变化就不重绘。
func set_deploy_zone(colors: Dictionary) -> void:
	if colors.size() == deploy_zone.size():
		var same := true
		for c in colors.keys():
			if not deploy_zone.has(c):
				same = false
				break
		if same:
			return
	deploy_zone = colors.duplicate()
	queue_redraw()

# 有棋子的格（出生区色罩在这些格上不画）。传进来没变化时不做重绘，避免每帧白刷。
func set_occupied(cells: Array) -> void:
	if cells.size() == occupied_cells.size():
		var same := true
		for c in cells:
			if not occupied_cells.has(c):
				same = false
				break
		if same:
			return
	occupied_cells.clear()
	for c in cells:
		occupied_cells[c] = true
	queue_redraw()

# 墓碑阵营底色开关（只有替补/落位阶段才亮，避免整局都把碑染成蓝/红）
func set_grave_faction(on: bool) -> void:
	if show_grave_faction == on:
		return
	show_grave_faction = on
	queue_redraw()

# 出生区色罩开关（只有部署英雄期间才亮，避免整局都把出生区染成蓝/红）
func set_spawn_zones(on: bool) -> void:
	if show_spawn_zones == on:
		return
	show_spawn_zones = on
	queue_redraw()

# 数字锚点（基线位置）：放格子右下角。字号 = 格半径 × 0.75，字形从基线往上长约占 0.72em，
# 所以锚点取 (0.46r, 0.40r)：字形的四角算下来仍在六边形内（右下角那点余量最小，0.92 ≤ 1）。
func _digit_anchor(center: Vector2) -> Vector2:
	return center + Vector2(grid.hex_size * 0.3, grid.hex_size * 0.7)

# 数字字号：跟随格子大小缩放（= 格半径 × 0.75），下限 14px
func _digit_font_px() -> int:
	return maxi(int(round(grid.hex_size * 0.75)), 14)

# 数字描边：黑色描边粗细 = 字号 × 这个系数（想更粗/更细改它；设 0 = 不描边）
const DIGIT_OUTLINE := 0.10

# 统一画法：白色字 + 黑描边、居中于锚点（障碍耐久 / 金矿剩余回合数共用）
func _draw_cell_digit(center: Vector2, txt: String) -> void:
	var f := ThemeDB.fallback_font
	var fs := _digit_font_px()
	var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := _digit_anchor(center) - Vector2(tw * 0.5, 0.0)
	var ow := int(round(float(fs) * DIGIT_OUTLINE))
	if ow > 0:
		# 先画一圈黑描边再盖白字（Godot 自带 draw_string_outline，不用手动多方向偏移）
		draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, Color(0, 0, 0))
	draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1))

# 把贴图按原始比例放进"边长 box 的正方形"里，居中画到格子中心（道具/金矿/障碍共用思路）
func _draw_cell_icon(tex: Texture2D, center: Vector2, box: float) -> void:
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	if tw <= 0.0 or th <= 0.0:
		return
	var s := box / maxf(tw, th)
	var size := Vector2(tw, th) * s
	draw_texture_rect(tex, Rect2(center - size * 0.5, size), false)

# 六边形顶点（flat-top：平边朝上，顶点在 0/60/…°）
func _hex_points(center: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts

func _draw_hex_fill(center: Vector2, radius: float, fill: Color) -> void:
	draw_colored_polygon(_hex_points(center, radius), fill)

func _draw_hex_outline(center: Vector2, radius: float, line: Color) -> void:
	draw_polyline(_closed(_hex_points(center, radius)), line, 2.0, true)

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
