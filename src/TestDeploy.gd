class_name TestDeploy
extends Node2D
## 自由部署测试场景：从全部角色中任选，点棋盘任意格放到我方/敌方任意位置，然后开战测试。

var grid: HexGrid
var board_view: BoardView
var board_origin := Vector2.ZERO

var picked := ""               # 当前在卡池中选中的 hero_id
var target_side := 0           # 0=我方(下) 1=敌方(上)
var player_units := {}         # cell -> hero_id
var enemy_units := {}          # cell -> hero_id
var _previews: Dictionary = {} # cell -> Unit 预览

const BOARD_W := 7
const BOARD_H := 9   # 与主战斗棋盘 board_size=(7,9) 一致，避免放置坐标越界
const HEX := 48.0

func _ready() -> void:
	grid = HexGrid.new(BOARD_W, BOARD_H, HEX)
	grid.top_cap_cols = [1, 3, 5]
	board_origin = _calc_origin()
	board_view = BoardView.new(grid, board_origin)
	add_child(board_view)
	_build_ui()

func _calc_origin() -> Vector2:
	var vsize := get_viewport().get_visible_rect().size
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for cell in grid.all_cells():
		var p := grid.cell_to_world(cell)
		minx = min(minx, p.x)
		miny = min(miny, p.y)
		maxx = max(maxx, p.x)
		maxy = max(maxy, p.y)
	var bw := (maxx - minx) + 2.0 * HEX
	var bh := (maxy - miny) + 2.0 * HEX
	return Vector2((vsize.x - bw) / 2.0 - minx + HEX, 70.0 - miny + HEX)

func _build_ui() -> void:
	var hud := CanvasLayer.new()
	hud.layer = 50
	add_child(hud)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(root)

	var vsize := get_viewport().get_visible_rect().size

	# 顶部：标题 + 阵营切换 + 计数
	var top := PanelContainer.new()
	top.position = Vector2(0, 0)
	top.size = Vector2(vsize.x, 60)
	top.add_theme_stylebox_override("panel", _panel(Color(0.08, 0.08, 0.12, 0.9)))
	root.add_child(top)
	var top_r := HBoxContainer.new()
	top_r.position = Vector2(12, 8)
	top_r.size = Vector2(vsize.x - 24, 44)
	top_r.alignment = BoxContainer.ALIGNMENT_CENTER
	top_r.add_theme_constant_override("separation", 14)
	top.add_child(top_r)
	var title := Label.new()
	title.text = "自由部署测试"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	top_r.add_child(title)
	top_r.add_child(_side_button("我方", 0))
	top_r.add_child(_side_button("敌方", 1))
	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 15)
	_count_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	top_r.add_child(_count_label)

	# 底部：角色卡池（可滚动）+ 按钮
	var bottom := PanelContainer.new()
	bottom.position = Vector2(0, vsize.y - 260)
	bottom.size = Vector2(vsize.x, 260)
	bottom.add_theme_stylebox_override("panel", _panel(Color(0.08, 0.08, 0.12, 0.92)))
	root.add_child(bottom)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(8, 8)
	scroll.size = Vector2(vsize.x - 16, 170)
	bottom.add_child(scroll)
	var gridc := GridContainer.new()
	gridc.columns = 3
	gridc.add_theme_constant_override("h_separation", 8)
	gridc.add_theme_constant_override("v_separation", 8)
	scroll.add_child(gridc)
	for id in DataRegistry.heroes.keys():
		var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
		var b := Button.new()
		b.text = def.display_name
		b.add_theme_font_size_override("font_size", 13)
		b.custom_minimum_size = Vector2(0, 34)
		b.pressed.connect(_pick.bind(id))
		gridc.add_child(b)

	var btn_row := HBoxContainer.new()
	btn_row.position = Vector2(8, 188)
	btn_row.size = Vector2(vsize.x - 16, 60)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 18)
	bottom.add_child(btn_row)
	var start_btn := Button.new()
	start_btn.text = "开始对局"
	start_btn.custom_minimum_size = Vector2(170, 48)
	start_btn.add_theme_font_size_override("font_size", 18)
	start_btn.pressed.connect(_on_start)
	btn_row.add_child(start_btn)
	var clear_btn := Button.new()
	clear_btn.text = "清空"
	clear_btn.custom_minimum_size = Vector2(90, 48)
	clear_btn.pressed.connect(_on_clear)
	btn_row.add_child(clear_btn)

	_status_label = Label.new()
	_status_label.position = Vector2(12, vsize.y - 300)
	_status_label.size = Vector2(vsize.x - 24, 30)
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	root.add_child(_status_label)

	_refresh_status()

var _count_label: Label
var _status_label: Label

func _panel(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	return sb

func _side_button(text: String, side: int) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(70, 40)
	b.pressed.connect(func(): target_side = side; _refresh_status())
	return b

func _pick(id: String) -> void:
	picked = id
	var def := DataRegistry.get_hero(id)
	_status_label.text = "已选：%s —— 点击棋盘放置到%s侧" % [def.display_name, "我方" if target_side == 0 else "敌方"]
	AudioManager.play("select")

func _on_clear() -> void:
	player_units.clear()
	enemy_units.clear()
	for u in _previews.values():
		if is_instance_valid(u):
			u.queue_free()
	_previews.clear()
	_refresh_status()

func _refresh_status() -> void:
	if _count_label:
		_count_label.text = "我%d 敌%d" % [player_units.size(), enemy_units.size()]

# 放置预览（点击棋盘格）
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var cell := grid.world_to_cell(get_global_mouse_position() - board_origin)
	if not grid.in_bounds(cell):
		return
	if picked == "":
		_status_label.text = "先在下方卡池点选一个角色。"
		return
	_place(cell)

func _place(cell: Vector2i) -> void:
	var def := DataRegistry.get_hero(picked)
	if def == null:
		return
	# 移除该格原有预览
	if _previews.has(cell):
		if is_instance_valid(_previews[cell]):
			_previews[cell].queue_free()
		_previews.erase(cell)
	var u := Unit.new(def, target_side, cell, HEX * 0.82)
	u.position = board_view.cell_world_center(cell)
	u.set_selected(false)
	add_child(u)
	_previews[cell] = u
	if target_side == 0:
		player_units[cell] = picked
		enemy_units.erase(cell)
	else:
		enemy_units[cell] = picked
		player_units.erase(cell)
	_refresh_status()
	_status_label.text = "已放置 %s 到%s" % [def.display_name, "我方" if target_side == 0 else "敌方"]

func _on_start() -> void:
	GameState.clear_placement()
	var p_ids: Array = []
	var e_ids: Array = []
	for cell in player_units.keys():
		GameState.player_placement[cell] = player_units[cell]
		p_ids.append(player_units[cell])
	for cell in enemy_units.keys():
		GameState.enemy_placement[cell] = enemy_units[cell]
		e_ids.append(enemy_units[cell])
	GameState.player_deck = p_ids
	GameState.enemy_deck = e_ids
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
