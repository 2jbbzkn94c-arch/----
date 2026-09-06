class_name QuickTest
extends Control
## 快速角色测试场（自由部署沙箱）：勾选 8 名我方可上角色。
## 开局首发 3v3（我方前 3、敌方 3），其余为替补；无 3 人判负（替补用尽才负）。
## 替补队伍 = 你选的 8 人里没上场的 5 人。

const MIN_PICK := 8
const MAX_PICK := 8

var _selected: Array[String] = []
var _btns: Dictionary = {}     # hero_id -> Button
var _count_label: Label
var _status_label: Label
var _start_btn: Button

# 测试场里我方可上场的格子（底部行）与敌方占位
const PLAYER_CELLS := [Vector2i(2, 8), Vector2i(4, 8), Vector2i(1, 8), Vector2i(5, 8), Vector2i(3, 8)]
const ENEMY_DUMMIES := ["hero_13", "hero_12", "hero_23", "hero_11", "hero_15"]
const ENEMY_CELLS := [Vector2i(1, 0), Vector2i(3, 0), Vector2i(5, 0), Vector2i(0, 1), Vector2i(6, 1)]

func _ready() -> void:
	_build()

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(24, 36)
	vbox.size = Vector2(vsize.x - 48, vsize.y - 60)
	vbox.add_theme_constant_override("separation", 10)
	add_child(vbox)

	var title := Label.new()
	title.text = "快速角色测试"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 18)
	_count_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_count_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	# 卡池
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for id in DataRegistry.heroes.keys():
		var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
		var b := Button.new()
		b.text = def.display_name
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(0, 42)
		b.toggle_mode = true
		b.pressed.connect(_toggle.bind(id))
		_btns[id] = b
		grid.add_child(b)

	var _start_btn2 := HBoxContainer.new()
	_start_btn2.alignment = BoxContainer.ALIGNMENT_CENTER
	_start_btn2.add_theme_constant_override("separation", 18)
	vbox.add_child(_start_btn2)
	_start_btn = Button.new()
	_start_btn.text = "开始对局"
	_start_btn.custom_minimum_size = Vector2(180, 52)
	_start_btn.add_theme_font_size_override("font_size", 19)
	_start_btn.pressed.connect(_on_start)
	_start_btn2.add_child(_start_btn)
	var clear_btn := Button.new()
	clear_btn.text = "清空"
	clear_btn.custom_minimum_size = Vector2(90, 52)
	clear_btn.add_theme_font_size_override("font_size", 16)
	clear_btn.pressed.connect(_on_clear)
	_start_btn2.add_child(clear_btn)
	var menu_btn := Button.new()
	menu_btn.text = "返回选卡"
	menu_btn.custom_minimum_size = Vector2(110, 52)
	menu_btn.pressed.connect(_on_menu)
	_start_btn2.add_child(menu_btn)

	_refresh()

func _toggle(id: String) -> void:
	if _selected.has(id):
		_selected.erase(id)
	else:
		if _selected.size() >= MAX_PICK:
			_status_label.text = "最多同时测试 %d 个角色。" % MAX_PICK
			_btns[id].set_pressed_no_signal(false)
			return
		_selected.append(id)
	_refresh()

func _refresh() -> void:
	_count_label.text = "已选 %d / %d" % [_selected.size(), MAX_PICK]
	_start_btn.disabled = _selected.size() < MIN_PICK
	for id in _btns.keys():
		_btns[id].set_pressed_no_signal(_selected.has(id))
	if _selected.size() == 0:
		_status_label.text = "勾选 8 名角色（前 3 名首发，后 5 名替补），敌方自动配好 3 首发。"
	else:
		var names: Array[String] = []
		for id in _selected:
			names.append(DataRegistry.heroes[id].display_name)
		_status_label.text = "将测试： " + "、 ".join(names) + "（首发=前3，其余替补）"

func _on_clear() -> void:
	_selected.clear()
	_refresh()

func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _on_start() -> void:
	if _selected.size() != MAX_PICK:
		return
	GameState.clear_placement()
	GameState.no_death_limit = true   # 自由部署沙箱：无 3 人判负，替补用尽才算负
	# 首发各 3 名直接摆到出生格（我方=勾选前 3，敌方=固定靶前 3）
	for i in 3:
		GameState.player_placement[PLAYER_CELLS[i]] = _selected[i]
		GameState.enemy_placement[ENEMY_CELLS[i]] = ENEMY_DUMMIES[i]
	# 完整队伍：首发 + 替补（我方 8 人，敌方 5 人靶子）
	GameState.player_deck = _selected.duplicate()
	GameState.enemy_deck = ENEMY_DUMMIES.duplicate()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
