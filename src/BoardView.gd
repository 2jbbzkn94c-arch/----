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
# 【2026-09-28·用户要求「开场时格子一个一个从天上掉下来，然后还有障碍和 buff」】
#   开场演出的**纵向偏移**（像素；正 = 往下）。三张表分开 ⇒ 三个阶段能各自错开：
#     `cell_drop`（格子）→ `obstacle_drop`（障碍）→ `item_drop`（增益道具/金矿）。
#   没登记 = 0（正常位置）；由 `Battle._play_board_intro()` 驱动，演完清空。
var cell_drop: Dictionary = {}       # cell -> float
var obstacle_drop: Dictionary = {}   # cell -> float
var item_drop: Dictionary = {}       # cell -> float
# 【2026-09-29·用户要求「格子改成从下往上一排一排冒出来」→ 随后「**不要有格子从小变大的动画**」】
#   格子的"出现进度"：cell -> 0~1（没登记 = 1 = 正常）。
#   0 = 还没出现（**尺寸照旧、只是全透明**），1 = 正常 ⇒ 逐排"直接现身"，**不做任何缩放**。
#   由 `Battle._play_board_intro()` 一排一排地驱动（`_set_cell_show()`），演出结束清空。
var cell_show: Dictionary = {}
# 该格当前的出现进度（0~1）与线透明度（进度直接当透明度：一排 0.30 秒淡入）
func _cell_show_v(cell: Vector2i) -> float:
	return clampf(float(cell_show.get(cell, 1.0)), 0.0, 1.0)

func _cell_alpha(cell: Vector2i) -> float:
	return _cell_show_v(cell)
# ---- 【2026-09-29·用户口径「把背景换成地图，然后在上面画棋盘」】----
#   本层不画任何"格子面"：地面就是 `Battle` 本局抽中的那张地图贴图（`Battle.BATTLE_BG_MAPS` 随机池，
#   联机两端同种子抽同一张；旧名 `BATTLE_BG_CANDIDATES` 已随"两张随机"改成 `BATTLE_BG_MAPS`）。
#   棋盘 = **直接画在这张地面上的一层六边形**：
#     ① 每格一层极淡的"内凹"压暗（`CELL_SCRIM`，0 = 不压）—— 让对局区从地面里收进去一点；
#     ② 每格一点随机的明暗差（`CELL_SHADE`）—— 一块一块的"手工感"，这是"看起来像一个个格子"的一半；
#     ③ 格子边界 = **一条黑格线**（见下面 `GRID_LINE`）：画在格边本身、相邻格共用一条，
#        所以六边形严丝合缝贴在一起（早期版本画在格子内侧，会出现"双线/间距不匀"）。
#   所以"换地图"= 增删 `Battle.BATTLE_BG_MAPS` 里的行，代码不用动。
#   ⚠️ 原来那套"逐格铺木纹贴片"（`TILE_TEXS` / `TILE_TINT` / `tile_pick` / `set_tile_seed` / `_draw_cell_tile`）
#     已整块删掉 —— 用户报的"贴片感"就出在它身上，现在木纹由整张地图提供、天然连续。
# ---- 格子边界：**黑色格线，画在格边本身**（2026-09-29·用户实机迭代到第四版定稿口径）----
#   用户原话：「**还是改成黑色**，现在六边形没有贴在一起，显得有些线条又粗又细」⇒ 两个结论：
#     ① 颜色回到**黑**（不透明 `Color(0,0,0,1)`）；
#     ② **`GRID_LINE_INSET` 必须 = 0**：上一版把线画在每格**内侧**，于是相邻两格的线各画一条、
#        中间夹着一道没画的缝 ⇒ 六边形之间看着"没贴在一起"，而且两条 3px 的线并排叠成 ~6px、
#        在顶点附近还会互相错开 ⇒ 就是用户说的"又粗又细"。
#        画在**格边本身**：相邻两格共用同一条线 ⇒ 六边形严丝合缝贴在一起，粗细处处一致。
#   ⚠️ 为什么这里不怕"两格各画一次"：颜色是**不透明**的（alpha 1.0）⇒ 画第二遍与第一遍完全一样，
#     不会像半透明/深棕那样叠出深浅差。（想改回半透明就必须把 `GRID_LINE_INSET` 调回 1.5 以上。）
#   ⚠️ 常用拧法：嫌粗/嫌细 → `GRID_LINE_W`（现 2.8；2.0 很细、4.0 很重）；
#     嫌纯黑太硬 → 把 `GRID_LINE` 改成暖黑 `Color(0.10, 0.06, 0.04, 1.0)`（仍是线，不会发灰）；
#     想柔一点（透出地面）→ 降 alpha，但同时要把 `GRID_LINE_INSET` 调回 1.5 以上，否则会一深一浅。
#   另一条**备用路线**：`EDGE_LIGHT` / `EDGE_DARK` = 「内棱」（把每格当板子打光，上侧受光、下侧背光）。
#   【2026-09-29·用户要求「能不能让棋盘更加立体感点」】**黑线保留，另外把内棱开回来当"槽口"**：
#     黑线是缝，缝的两侧各一道内棱（缝上方那格的**下棱偏暗**、缝下方那格的**上棱偏亮**）
#     ⇒ 看上去是一道有厚度、能接光的凹槽，而不是一条平贴的线 ✓（这就是"立体感"的主要来源）
const GRID_LINE := Color(0.0, 0.0, 0.0, 1.0)          # 黑色格线（不透明；alpha 0 = 不画）
const GRID_LINE_W := 2.8                              # 黑线宽（像素）
const GRID_LINE_INSET := 0.0                          # 0 = 画在格边本身（相邻格共用一条 ⇒ 六边形贴在一起）
# 【2026-09-29·用户要求「立体感还能再强点吗」】内棱加粗加深（0.14/0.22 → **0.24/0.38**、宽 3.0 → **3.8**），
#   并在每道棱**往里再补一道更宽的柔光棱**（`EDGE_SOFT_*`，往格内渐隐）⇒ 槽口看着更厚、更像刻出来的。
# 【2026-09-30·用户口径「能不能让棋子的立体感比棋盘强，把棋盘立体感弄低点」】⇒ **棋盘这一层整体压到约 4 成**
#   （0.24/0.38 → **0.10/0.16**、宽 3.8 → **3.0**、柔光 0.13/0.10 → **0.05/0.04**、柔光宽 10 → **7**）：
#   格子数量多（一屏 ~37 格）⇒ 每格只需一点点起伏就够，压过头会把棋子压没。
#   ⚠️ 这两组是"立体感"的主旋钮；想再淡就继续往下（0.06/0.10），嫌太平就往回加。
const EDGE_LIGHT := Color(1.0, 0.96, 0.90, 0.10)      # 上侧内棱（受光；0 = 关这道棱）
const EDGE_DARK := Color(0.06, 0.04, 0.025, 0.16)     # 下侧内棱（背光；0 = 关这道棱）
const EDGE_W := 3.0                                   # 内棱线宽（像素）
const EDGE_INSET := 2.0                               # 内棱相对格边往自己格子里缩多少像素
const EDGE_SOFT_W := 7.0                              # 柔光棱宽度（像素；往格内渐隐，0 = 不画）
const EDGE_SOFT_A := 0.05                             # 柔光棱透明度（受光那侧用 `EDGE_LIGHT` 的色）
const EDGE_SOFT_LIGHT_A := 0.04                       # 柔光棱（背光那侧用 `EDGE_DARK` 的色）
# ---- 棋盘整体的立体感 ----
# 【2026-09-29·用户要求「让棋盘更加立体感点」】当时加了这三层；**随后用户要求「棋盘不要加黑色图层」
#   ⇒ 压暗类全部关掉**（`BOARD_SHADOW_A` / `BOARD_SHADOW_SOFT_A` / `EDGE_RIM_A` / `CELL_SCRIM` /
#   `CELL_SHADE` 全设成 0）—— 只留"黑格线 + 槽口内棱"，地面上不再有任何压暗层。
#   想再要一点纵深：把某个值往回加一点即可（比如 `CELL_SCRIM` 0.06、`BOARD_SHADOW_A` 0.12、
#   `EDGE_RIM_A` 0.08、`CELL_SHADE` 0.03）；每个都能单独设 0 关掉。
const BOARD_SHADOW_A := 0.0                           # 外缘投影强度（0 = 不画）
const BOARD_SHADOW_W := 3.5                           # 投影线宽（像素）
const BOARD_SHADOW_DROP := 3.0                        # 投影下移像素（光源在上方）
const BOARD_SHADOW_SOFT_A := 0.0                      # 第二层更软的投影强度
const BOARD_SHADOW_SOFT_W := 8.0                      # 第二层线宽
const EDGE_RIM_A := 0.0                               # 最外圈格子额外压暗多少（0 = 不压）
const CELL_SCRIM := 0.0                               # 每格压暗多少（0 = 完全不压）
const CELL_SCRIM_COLOR := Color(0.06, 0.04, 0.03)     # 压暗往哪个色偏（暖黑）
const CELL_SHADE := 0.0                               # 每格随机明暗差（0 = 全部一样亮）
# 出生区/高亮改成"半透明色罩"盖在地面上（否则会把地面整块盖住看不见）
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
# 【2026-09-29·用户要求「加了个炸弹，替换炸弹」】炸弹标记由**代码画**（黑底橙芯 + 淡红圈，见 `_draw()`）
#   改成贴图：用户提供的 `assets/图标/炸弹.png`（281×384 竖版，带引线）。放在 `图标/` 而不是 `美术资源/`
#   是**用户自己放的位置**，照用即可（同目录还有喊话/名片等 UI 图）。
const BOMB_TEX := preload("res://assets/图标/炸弹.png")
# 【2026-10-02·用户要求「图标文件夹有个耐久度背景，把金矿、障碍物耐久的数字加上这个背景，
#   放在六边形的右下角，现在的数字大小需要缩小，和血量标志一样」】
#   使用者 = **障碍物耐久**（`_draw()` 里 `obstacles[cell]`）与**金矿剩余回合数**（`gold_left[cell]`）——
#   两者共用同一个数字画法 `_draw_cell_digit()`（数字锚点都在格子右下角，见 `_digit_anchor()`）。
const DUR_BG_TEX := preload("res://assets/图标/耐久度背景.png")
# 背景框边长 = 字号 × 这个系数（背景按原比例放进方框、居中画在数字底下；想更大/更小只改这一个数）
# 【2026-10-03·用户先「障碍物耐久度的盾牌放大点」、随后「金矿也要的耐久度背景也变大」】⇒ 两处统一放大：
#   1.55 → **1.55 × 1.20 = 1.86**（障碍与金矿**共用同一个值**，不再分档）。
const DIGIT_BG_BOX := 1.86
# 炸弹贴图尺寸：高 = 格高 × 这个系数（与酒桶 `OBSTACLE_H` 0.60 / 墓碑 `GRAVE_H` 0.66 同一套口径 ——
#   正好落在六边形格子里、不压相邻格；宽按原图比例自动算，不会拉伸变形）。想更大/更小只改这一个数。
# 【2026-09-29·用户要求「炸弹缩小点」】0.62 → **0.50**（去掉白底后图案顶满整框，同一个系数下看着偏大）。
const BOMB_H := 0.50
# 【2026-09-29·用户报「炸弹暗一点，有点格格不入」】贴图调制色：把炸弹整体压暗一档、略微偏冷，
#   好和木地板/酒桶那套色调融在一起（做法与 `_draw_cell_icon()` 的 `tint` 参数同一个道理：只乘一层色，**原图不动**）。
#   调法：三个分量一起调小 = 更暗（0.6 就很暗了）；想偏暖就把蓝分量调低、想偏冷就把红分量调低。
const BOMB_TINT := Color(0.78, 0.79, 0.82, 1.0)
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

# 出生区色罩是否显示：**只在部署英雄时**亮（开局选人/放位阶段由 Battle 打开，部署完就关）
var show_spawn_zones := false
# 格子绘制半径系数：1.0 = 相邻格严丝合缝（间隙 0）。
# 相邻六边形中心距 = √3 × hex_size，各自画到 hex_size 半径时正好在外接处贴合。
# 【2026-09-29】现在"格子"只是地面上的一圈刻痕 ⇒ 这个系数同时决定刻痕网的疏密描边；
# 想要一条细缝（看着像瓷砖）就调小一点，比如 0.985。
const CELL_R := 1.0

func _init(g: HexGrid, origin: Vector2 = Vector2.ZERO) -> void:
	grid = g
	board_origin = origin

func _ready() -> void:
	z_index = 1
	_rebuild_border()
	queue_redraw()

# ---- 【2026-09-29·用户要求「让棋盘更加立体感点」】棋盘外缘：哪几条边在"最外圈" + 哪些格是边格 ----
#   判据：沿这条边的**外法线**方向、隔一个格距（√3 × 半径）找邻格 —— 找不到（棋盘外/顶帽行缺口）
#   ⇒ 这条边是外缘边。只在 `_ready()` 算一次（棋盘几何此后不变），绘制时直接用。
var _border_edges: Array = []      # 每项 = [起点 Vector2, 终点 Vector2]（本节点本地坐标）
var _border_cells: Array = []      # 最外圈格子（用于"内圈压暗"）

func _rebuild_border() -> void:
	_border_edges.clear()
	_border_cells.clear()
	if grid == null:
		return
	var member := {}
	for c in grid.all_cells():
		member[c] = true
	var all: Array = grid.all_cells()
	var r := grid.hex_size * CELL_R
	for cell in all:
		var center := board_origin + grid.cell_to_world(cell)
		var pts := _hex_points(center, r)
		var is_border := false
		for i in 6:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[(i + 1) % 6]
			var mid := (a + b) * 0.5
			var n := (b - a).orthogonal().normalized()
			if n.dot(mid - center) < 0.0:
				n = -n                     # 取朝外的法线
			var outside := center + n * (sqrt(3.0) * r)   # 邻格中心（几何位置）
			# 这个位置上真的有相邻格吗？（顶帽行/棋盘边界处会没有 ⇒ 那就是外缘）
			var found := false
			for other in all:
				if other == cell:
					continue
				if grid.distance(cell, other) != 1:
					continue
				if (board_origin + grid.cell_to_world(other)).distance_to(outside) < r * 0.35:
					found = true
					break
			if not found:
				_border_edges.append([a, b])
				is_border = true
		if is_border:
			_border_cells.append(cell)

# 棋盘外缘投影：两层（窄而实 + 宽而淡），整体往下偏 ⇒ 棋盘像压在地面上
func _draw_board_shadow() -> void:
	if BOARD_SHADOW_A <= 0.0 and BOARD_SHADOW_SOFT_A <= 0.0:
		return
	if not cell_drop.is_empty():
		return   # 开场"格子从天上掉下来"期间不画棋盘外缘阴影（那时棋盘还没拼好，会看着像地上先有一圈黑影）
	var drop := Vector2(0.0, BOARD_SHADOW_DROP)
	for e in _border_edges:
		var a: Vector2 = e[0] + drop
		var b: Vector2 = e[1] + drop
		if BOARD_SHADOW_SOFT_A > 0.0 and BOARD_SHADOW_SOFT_W > 0.0:
			draw_line(a, b, Color(0.04, 0.03, 0.02, BOARD_SHADOW_SOFT_A), BOARD_SHADOW_SOFT_W, true)
		if BOARD_SHADOW_A > 0.0 and BOARD_SHADOW_W > 0.0:
			draw_line(a, b, Color(0.04, 0.03, 0.02, BOARD_SHADOW_A), BOARD_SHADOW_W, true)

func _draw() -> void:
	if grid == null:
		return
	var cells: Array = grid.all_cells()
	# 【2026-09-29·用户口径「在地面上画棋盘」+「让棋盘更加立体感点」】分段画：
	#   ① 棋盘外缘投影（只沿最外圈那几条边，往下偏移）→ ② 最外圈格子额外压暗（内圈阴影）
	#   → ③ 每格内凹压暗 → ④ 每格随机明暗差 → ⑤ 出生区/高亮色罩 → ⑥ 黑格线
	#   → ⑦ 上侧受光 / 下侧背光内棱（槽口，立体感主力）。
	#   地面本身是 Battle 那张地图贴图（本层不画任何格子面 ⇒ 木纹天然连续、没有贴片感）。
	_draw_board_shadow()
	if EDGE_RIM_A > 0.0:
		for cell in _border_cells:
			_draw_hex_fill(_cell_draw_center(cell), grid.hex_size * CELL_R,
				Color(0.06, 0.04, 0.03, EDGE_RIM_A))
	for cell in cells:
		_draw_cell_scrim(cell, _cell_draw_center(cell))
	for cell in cells:
		_draw_cell_shade(cell, _cell_draw_center(cell))
	for cell in cells:
		var center := _cell_draw_center(cell)
		var tint: Variant = _cell_tint(cell)
		if tint != null:
			_draw_hex_fill(center, grid.hex_size * CELL_R, tint)   # 出生区/高亮：半透明色罩
	if GRID_LINE.a > 0.0:
		for cell in cells:
			_draw_cell_grid_line(cell, _cell_draw_center(cell))
	if EDGE_LIGHT.a > 0.0:
		for cell in cells:
			_draw_cell_edge_light(cell, _cell_draw_center(cell))
	if EDGE_DARK.a > 0.0:
		for cell in cells:
			_draw_cell_edge_dark(cell, _cell_draw_center(cell))
	# 炸弹标记（【2026-09-29·用户要求「加了个炸弹，替换炸弹」】改用贴图 `BOMB_TEX`；
	#   尺寸口径与酒桶/墓碑一致：高 = 格高 × `BOMB_H`、宽按原图比例。原来这里是程序画的
	#   "黑底圆 + 橙芯 + 淡红圈"三笔。）
	for cell in bombs.keys():
		var center := board_origin + grid.cell_to_world(cell) \
			+ Vector2(0.0, float(cell_drop.get(cell, 0.0)))
		var bomb_cell_h := grid.hex_size * sqrt(3.0) * CELL_R
		_draw_cell_icon(BOMB_TEX, center, bomb_cell_h * BOMB_H, BOMB_TINT)
	# 障碍物：酒桶素材。桶比格子窄高，按"桶高 = 格高 × OBSTACLE_H"等比放入格中（不拉伸变形）
	for cell in obstacles.keys():
		var center := board_origin + grid.cell_to_world(cell) \
			+ Vector2(0.0, float(cell_drop.get(cell, 0.0)) + float(obstacle_drop.get(cell, 0.0)))
		var cell_h := grid.hex_size * sqrt(3.0) * CELL_R
		var bh := cell_h * OBSTACLE_H
		var bw := bh * float(OBSTACLE_TEX.get_width()) / float(OBSTACLE_TEX.get_height())
		draw_texture_rect(OBSTACLE_TEX, Rect2(center - Vector2(bw, bh) * 0.5, Vector2(bw, bh)), false)
		# 剩余耐久：数字画在格子右下角（带耐久背景，见 `_draw_cell_digit`）
		_draw_cell_digit(center, str(int(obstacles[cell])))
	# 增益道具/金矿（有美术素材的直接贴图；移动道具仍用程序画的蓝点）
	for cell in buff_items.keys():
		if hidden_item_cells.has(cell):
			continue   # 【圣诞老人】礼物还在飞：这一格先不画（落地后 Battle 解除隐藏）
		var center := board_origin + grid.cell_to_world(cell) \
			+ Vector2(0.0, float(cell_drop.get(cell, 0.0)) + float(item_drop.get(cell, 0.0)))
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
		# 金矿：右下角显示剩余回合数（3→2→1，到0消失），与障碍耐久同一套画法（背景用默认大小）
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

# 某一格**画的时候**的中心：正常位置 + 开场"从天上掉下来"的演出偏移（`cell_drop`）。
# 【2026-09-29】现在掉下来的是"地面上的这一圈刻痕"（地面本身是背景那张地图，不动）。
func _cell_draw_center(cell: Vector2i) -> Vector2:
	return board_origin + grid.cell_to_world(cell) + Vector2(0.0, float(cell_drop.get(cell, 0.0)))

# 每格的"内凹"压暗（`CELL_SCRIM` = 0 就不画）：让对局区从地面里收进去一点，格子边界更清楚。
func _draw_cell_scrim(cell: Vector2i, center: Vector2) -> void:
	if CELL_SCRIM <= 0.0:
		return
	draw_colored_polygon(_hex_points(center, grid.hex_size * CELL_R),
		Color(CELL_SCRIM_COLOR.r, CELL_SCRIM_COLOR.g, CELL_SCRIM_COLOR.b, CELL_SCRIM * _cell_alpha(cell)))

# 每格的随机明暗差（`CELL_SHADE` = 0 就不画）：值由格坐标算出来（稳定、两端一致、不用种子），
# 亮的一半盖一层白、暗的一半盖一层黑 ⇒ 一格一格像手工铺的板子（这是"像一个一个格子"的一半功劳）。
func _draw_cell_shade(cell: Vector2i, center: Vector2) -> void:
	if CELL_SHADE <= 0.0:
		return
	var v := _cell_shade_value(cell)
	var a := absf(v) * CELL_SHADE
	if a < 0.004:
		return
	var c := Color(1.0, 1.0, 1.0, a) if v > 0.0 else Color(0.0, 0.0, 0.0, a)
	draw_colored_polygon(_hex_points(center, grid.hex_size * CELL_R), c)

# 格坐标 → -1~1 的稳定小噪声（不依赖 RNG ⇒ 每局、联机两端都是同一套明暗）
func _cell_shade_value(cell: Vector2i) -> float:
	var h: int = int(cell.x) * 73856093 ^ int(cell.y) * 19349663
	h = (h ^ (h >> 13)) * 1274126177
	return float((h >> 8) & 255) / 127.5 - 1.0

# 白格线（默认路线）：一条白线绕六边形一圈，画在格边**内侧** ⇒ 相邻两格各画各的、互不叠加，
# 整片亮度均匀（压在格边上的画法会被两格各画一次，内外深浅不一）。
# 【2026-09-29·用户要求「格子从下往上一排一排冒出来」→ 随后「**不要有格子从小变大的动画**」】
#   按 `cell_show`（出现进度）**只做淡入**：`_cell_alpha()` 0→1，**半径与线宽都不动**。
func _draw_cell_grid_line(cell: Vector2i, center: Vector2) -> void:
	var r := maxf(1.0, grid.hex_size * CELL_R - GRID_LINE_INSET)
	var col := Color(GRID_LINE.r, GRID_LINE.g, GRID_LINE.b, GRID_LINE.a * _cell_alpha(cell))
	draw_polyline(_closed(_hex_points(center, r)), col, GRID_LINE_W, true)

# ---- 格子边界的「内棱」（上一版路线，现在 alpha 默认 0 = 关；见文件顶部 `EDGE_*` 的说明）----
# 上侧 3 条边 = 受光内棱（画在自己格子内侧）· 下侧 3 条边 = 背光内棱（同样在自己格子内侧）。
# 顶点顺序来自 `_hex_points()`（平顶六边形）：0=右 1=右下 2=左下 3=左 4=左上 5=右上。
func _draw_cell_edge_light(cell: Vector2i, center: Vector2) -> void:
	var r := maxf(1.0, grid.hex_size * CELL_R)
	var a := _cell_alpha(cell)
	# 硬棱（贴着槽口）
	var pts := _hex_points(center, maxf(1.0, r - EDGE_INSET))
	var top := PackedVector2Array([pts[0], pts[5], pts[4], pts[3]])   # 上侧：右上 → 上 → 左上
	draw_polyline(top, Color(EDGE_LIGHT.r, EDGE_LIGHT.g, EDGE_LIGHT.b, EDGE_LIGHT.a * a), EDGE_W, true)
	# 柔光棱（再往里一道、更宽更淡 ⇒ 往格内渐隐，像受光面）
	if EDGE_SOFT_A > 0.0 and EDGE_SOFT_W > 0.0:
		var pts2 := _hex_points(center, maxf(1.0, r - EDGE_INSET - EDGE_W))
		var top2 := PackedVector2Array([pts2[0], pts2[5], pts2[4], pts2[3]])
		draw_polyline(top2, Color(EDGE_LIGHT.r, EDGE_LIGHT.g, EDGE_LIGHT.b, EDGE_SOFT_A * a),
			EDGE_SOFT_W, true)

func _draw_cell_edge_dark(cell: Vector2i, center: Vector2) -> void:
	var r := maxf(1.0, grid.hex_size * CELL_R)
	var a := _cell_alpha(cell)
	# 硬棱（贴着槽口）
	var pts := _hex_points(center, maxf(1.0, r - EDGE_INSET))
	var bottom := PackedVector2Array([pts[3], pts[2], pts[1], pts[0]])   # 下侧：左下 → 下 → 右下
	draw_polyline(bottom, Color(EDGE_DARK.r, EDGE_DARK.g, EDGE_DARK.b, EDGE_DARK.a * a), EDGE_W, true)
	# 柔光棱（再往里一道、更宽更淡 ⇒ 往格内渐隐，像背光面的过渡）
	if EDGE_SOFT_LIGHT_A > 0.0 and EDGE_SOFT_W > 0.0:
		var pts2 := _hex_points(center, maxf(1.0, r - EDGE_INSET - EDGE_W))
		var bottom2 := PackedVector2Array([pts2[3], pts2[2], pts2[1], pts2[0]])
		draw_polyline(bottom2, Color(EDGE_DARK.r, EDGE_DARK.g, EDGE_DARK.b, EDGE_SOFT_LIGHT_A * a),
			EDGE_SOFT_W, true)

# 该格要不要再盖一层色罩：高亮 > （仅部署阶段）出生区；都不需要时返回 null（露出地面）
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

# 数字锚点（基线位置）：放格子右下角。
# 取 (0.30r, 0.66r)：字号 0.392r、背景框 1.55×字号 ≈ 0.60r（障碍那处 1.86× ≈ 0.73r）⇒
# 障碍框下缘 ≈ 0.66r − 0.14r + 0.365r = 0.885r，贴着六边形底边 0.866r 但基本不出去
# （2026-10-03 为"把障碍盾牌放大点"把 y 从 0.68r 提到 0.66r，腾出这点余量）。
func _digit_anchor(center: Vector2) -> Vector2:
	return center + Vector2(grid.hex_size * 0.30, grid.hex_size * 0.66)

# 数字字号：**与棋子上的"血量标志"同一把尺子** ——
#   `Unit` 里血量/攻击数字是 `17.0 * (hex_radius / 39.0)`，而棋子 `hex_radius = grid.hex_size * 0.9`
#   （`Battle._spawn_unit()` 传 `hex_size * 0.9`）⇒ 这里 = `grid.hex_size * 17.0 * 0.9 / 39.0`。
#   历史：原来写 `grid.hex_size * 0.75`（≈ 血量标志的两倍），2026-10-02 用户要求缩小到一致。
const DIGIT_FONT_RATIO := 17.0 * 0.9 / 39.0

func _digit_font_px() -> int:
	return maxi(int(round(grid.hex_size * DIGIT_FONT_RATIO)), 10)

# 数字描边：黑色描边粗细 = 字号 × 这个系数（想更粗/更细改它；设 0 = 不描边）
const DIGIT_OUTLINE := 0.10

# 统一画法：**耐久度背景 + 白色字 + 黑描边**、居中于锚点（障碍耐久 / 金矿剩余回合数共用）——
# 【2026-10-02·用户要求】数字底下铺那张 `assets/图标/耐久度背景.png`（`DUR_BG_TEX`），
#   框按字号缩放（`DIGIT_BG_BOX`，2026-10-03 两处统一放大到 1.86），整组仍在格子右下角（见 `_digit_anchor()`）。
func _draw_cell_digit(center: Vector2, txt: String) -> void:
	var f := ThemeDB.fallback_font
	var fs := _digit_font_px()
	var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := _digit_anchor(center) - Vector2(tw * 0.5, 0.0)
	# 背景：以**字形中心**为锚（基线往上约 0.36em ≈ 一行大写字形的中心），按字号取框、原比例放入
	if DUR_BG_TEX != null:
		var bg_c := Vector2(p.x + tw * 0.5, p.y - float(fs) * 0.36)
		_draw_cell_icon(DUR_BG_TEX, bg_c, float(fs) * DIGIT_BG_BOX)
	var ow := int(round(float(fs) * DIGIT_OUTLINE))
	if ow > 0:
		# 先画一圈黑描边再盖白字（Godot 自带 draw_string_outline，不用手动多方向偏移）
		draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ow, Color(0, 0, 0))
	draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1))

# 把贴图按原始比例放进"边长 box 的正方形"里，居中画到格子中心（道具/金矿/障碍共用思路）
# `tint` = 贴图调制色（默认白色 = 原样画；用来把某张图压暗/调色，如炸弹那层 `BOMB_TINT`）
func _draw_cell_icon(tex: Texture2D, center: Vector2, box: float, tint: Color = Color(1, 1, 1, 1)) -> void:
	var tw := float(tex.get_width())
	var th := float(tex.get_height())
	if tw <= 0.0 or th <= 0.0:
		return
	var s := box / maxf(tw, th)
	var size := Vector2(tw, th) * s
	draw_texture_rect(tex, Rect2(center - size * 0.5, size), false, tint)

# 六边形顶点（flat-top：平边朝上，顶点在 0/60/…°）
func _hex_points(center: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts

func _draw_hex_fill(center: Vector2, radius: float, fill: Color) -> void:
	draw_colored_polygon(_hex_points(center, radius), fill)

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
