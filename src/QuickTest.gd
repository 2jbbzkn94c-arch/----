class_name QuickTest
extends Control
## 自由部署（测试）沙箱：分别组建"我方"和"敌方"各 8 人队伍（每队勾选 8 人）。
## 每队勾选顺序前 3 名为首发、后 5 名为替补；无 3 人判负，替补用完才算负。
## 战斗中可拖动撤下/换角，替补触发技能仅限带 <替补> 标签的英雄。

const TEAM_SIZE := 8
const STARTERS := 3
const MIN_PLAYER := 3   # 我方最少可选 3 名（首发三人即满）；敌方未选则自动随机 8 名

var _side := 0              # 当前编辑的队伍：0=我方 1=敌方
var _sel_p: Array[String] = []
var _sel_e: Array[String] = []
var _btns: Dictionary = {}  # hero_id -> Button
var _count_label: Label
var _status_label: Label
var _side_label: Label
var _start_btn: Button

# 测试场里各队可上场的格子（底部行我方 / 顶部敌方），只放首发 3 个
const PLAYER_CELLS := [Vector2i(2, 6), Vector2i(4, 6), Vector2i(1, 6)]
const ENEMY_CELLS := [Vector2i(1, 0), Vector2i(3, 0), Vector2i(5, 0)]

func _ready() -> void:
	_build()

func _cur() -> Array:
	return _sel_p if _side == 0 else _sel_e

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(24, 30)
	vbox.size = Vector2(vsize.x - 48, vsize.y - 60)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	var title := Label.new()
	title.text = "自由部署（测试）"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# 队伍切换：我方 / 敌方
	var side_row := HBoxContainer.new()
	side_row.alignment = BoxContainer.ALIGNMENT_CENTER
	side_row.add_theme_constant_override("separation", 14)
	vbox.add_child(side_row)
	_side_label = Label.new()
	_side_label.add_theme_font_size_override("font_size", 17)
	_side_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	side_row.add_child(_side_label)
	for i in 2:
		var sb := Button.new()
		sb.text = "编辑敌方" if i == 1 else "编辑我方"
		sb.custom_minimum_size = Vector2(120, 40)
		sb.pressed.connect(_pick_side.bind(i))
		side_row.add_child(sb)

	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 17)
	_count_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.75))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_count_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 14)
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

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 18)
	vbox.add_child(btn_row)
	_start_btn = Button.new()
	_start_btn.text = "开始对局"
	_start_btn.custom_minimum_size = Vector2(180, 52)
	_start_btn.add_theme_font_size_override("font_size", 19)
	_start_btn.pressed.connect(_on_start)
	btn_row.add_child(_start_btn)
	var clear_btn := Button.new()
	clear_btn.text = "清空当前队伍"
	clear_btn.custom_minimum_size = Vector2(150, 52)
	clear_btn.add_theme_font_size_override("font_size", 15)
	clear_btn.pressed.connect(_on_clear)
	btn_row.add_child(clear_btn)
	var menu_btn := Button.new()
	menu_btn.text = "返回选卡"
	menu_btn.custom_minimum_size = Vector2(110, 52)
	menu_btn.pressed.connect(_on_menu)
	btn_row.add_child(menu_btn)

	_refresh()

func _pick_side(s: int) -> void:
	_side = s
	_refresh()

func _toggle(id: String) -> void:
	var arr := _cur()
	if arr.has(id):
		arr.erase(id)
	else:
		if arr.size() >= TEAM_SIZE:
			_status_label.text = "每队上限 %d 人（前 %d 首发、其余替补）。" % [TEAM_SIZE, STARTERS]
			_btns[id].set_pressed_no_signal(false)
			return
		arr.append(id)
	_refresh()

func _refresh() -> void:
	_side_label.text = "当前编辑：%s" % ("敌方" if _side == 1 else "我方")
	_count_label.text = "我方 %d/%d   敌方 %d/%d" % [_sel_p.size(), TEAM_SIZE, _sel_e.size(), TEAM_SIZE]
	# 我方至少 MIN_PLAYER 名；敌方可不选（0 名）→ 开局自动随机 8 名
	var player_ok := _sel_p.size() >= MIN_PLAYER and _sel_p.size() <= TEAM_SIZE
	var enemy_ok := _sel_e.size() == 0 or _sel_e.size() <= TEAM_SIZE
	_start_btn.disabled = not (player_ok and enemy_ok)
	for id in _btns.keys():
		_btns[id].set_pressed_no_signal(_cur().has(id))
	if not player_ok or not enemy_ok:
		var hint := "请组建我方队伍：最少 %d 名（上限 %d，前 %d 名首发，其余替补）。当前先编辑%s。" % [MIN_PLAYER, TEAM_SIZE, STARTERS, "敌方" if _side == 1 else "我方"]
		if _sel_p.size() >= MIN_PLAYER and _sel_e.size() == 0:
			hint += "\n敌方未选择：开局将自动随机 8 名。"
		_status_label.text = hint
	else:
		_status_label.text = "我方：%s\n敌方：%s" % [_names(_sel_p), ("未选择（开局随机 8 名）" if _sel_e.size() == 0 else _names(_sel_e))]

func _names(arr: Array) -> String:
	var ns: Array[String] = []
	for id in arr:
		ns.append(DataRegistry.heroes[id].display_name)
	return "、".join(ns)

func _on_clear() -> void:
	_cur().clear()
	_refresh()

func _on_menu() -> void:
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _on_start() -> void:
	if _sel_p.size() < MIN_PLAYER or _sel_p.size() > TEAM_SIZE:
		return
	if _sel_e.size() > TEAM_SIZE:
		return
	var edeck: Array = _sel_e.duplicate()
	if edeck.size() == 0:
		# 敌方未选：从全英雄池随机挑 8 名（避免与我方已选重复）
		var pool: Array = DataRegistry.heroes.keys()
		var excl: Dictionary = {}
		for id in _sel_p:
			excl[id] = true
		var cand: Array = []
		for id in pool:
			if not excl.has(id):
				cand.append(id)
		cand.shuffle()
		for i in mini(TEAM_SIZE, cand.size()):
			edeck.append(cand[i])
	GameState.clear_placement()
	GameState.no_death_limit = true   # 自由部署沙箱：无 3 人判负，替补用完才算负
	# 首发各 3 名直接摆到出生格（若我方不足 3 首发时按实际前几名摆放）
	var p_first: Array = _sel_p.slice(0, STARTERS)
	var e_first: Array = edeck.slice(0, STARTERS)
	for i in p_first.size():
		GameState.player_placement[PLAYER_CELLS[i]] = p_first[i]
	for i in e_first.size():
		GameState.enemy_placement[ENEMY_CELLS[i]] = e_first[i]
	# 完整队伍：首发 + 替补（替补=各队剩余未上场的人）
	GameState.player_deck = _sel_p.duplicate()
	GameState.enemy_deck = edeck.duplicate()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
