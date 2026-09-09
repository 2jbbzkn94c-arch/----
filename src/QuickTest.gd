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
var _btns: Dictionary = {}  # hero_id -> HexCard
var _count_label: Label
var _status_label: Label
var _side_label: Label
var _start_btn: Button
var _pool_scroll: ScrollContainer = null   # 英雄池滚动容器（触屏拖动）
var _pool_touch_down := false              # 触屏按住英雄池中

# 测试场里各队可上场的格子（底部行我方 / 第一满行敌方），只放首发 3 个
const PLAYER_CELLS := [Vector2i(0, 6), Vector2i(2, 6), Vector2i(4, 6)]
const ENEMY_CELLS := [Vector2i(0, 1), Vector2i(2, 1), Vector2i(4, 1)]

func _ready() -> void:
	_build()
	set_process_input(true)   # 触屏拖动英雄池

func _cur() -> Array:
	return _sel_p if _side == 0 else _sel_e

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(24, 26)
	vbox.size = Vector2(vsize.x - 48, vsize.y - 60)
	vbox.add_theme_constant_override("separation", 12)
	add_child(vbox)

	var title := Label.new()
	title.text = "自由部署（测试）"
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# 队伍切换：我方 / 敌方
	var side_row := HBoxContainer.new()
	side_row.alignment = BoxContainer.ALIGNMENT_CENTER
	side_row.add_theme_constant_override("separation", 16)
	vbox.add_child(side_row)
	_side_label = Label.new()
	_side_label.add_theme_font_size_override("font_size", 22)
	_side_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	side_row.add_child(_side_label)
	for i in 2:
		var sb := Button.new()
		sb.text = "编辑敌方" if i == 1 else "编辑我方"
		sb.custom_minimum_size = Vector2(150, 54)
		sb.add_theme_font_size_override("font_size", 20)
		sb.pressed.connect(_pick_side.bind(i))
		side_row.add_child(sb)

	_count_label = Label.new()
	_count_label.add_theme_font_size_override("font_size", 22)
	_count_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.75))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_count_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 19)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	# 英雄池：与普通模式选人页同款（5 列蜂窝 HexCard、纵向滚动、触屏拖动）
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # 防左右滑
	_pool_scroll = scroll
	vbox.add_child(scroll)
	var hex_host := Control.new()
	hex_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hex_host)
	_build_hex_pool(hex_host)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 18)
	vbox.add_child(btn_row)
	_start_btn = Button.new()
	_start_btn.text = "开始对局"
	_start_btn.custom_minimum_size = Vector2(200, 66)
	_start_btn.add_theme_font_size_override("font_size", 25)
	_start_btn.pressed.connect(_on_start)
	btn_row.add_child(_start_btn)
	var clear_btn := Button.new()
	clear_btn.text = "清空当前队伍"
	clear_btn.custom_minimum_size = Vector2(180, 66)
	clear_btn.add_theme_font_size_override("font_size", 21)
	clear_btn.pressed.connect(_on_clear)
	btn_row.add_child(clear_btn)
	var menu_btn := Button.new()
	menu_btn.text = "返回选卡"
	menu_btn.custom_minimum_size = Vector2(140, 66)
	menu_btn.add_theme_font_size_override("font_size", 21)
	menu_btn.pressed.connect(_on_menu)
	btn_row.add_child(menu_btn)

	_refresh()

# 与普通模式英雄池同款：5 列平顶蜂窝 HexCard，按种族分组（人族→机械→兽族→精灵→魔族），超高可滚动
func _build_hex_pool(host: Control) -> void:
	var ids: Array = DataRegistry.heroes.keys()
	ids.sort_custom(func(a: String, b: String):
		var da := DataRegistry.get_hero(a)
		var db := DataRegistry.get_hero(b)
		var ra := da.race if da != null else 99
		var rb := db.race if db != null else 99
		if ra != rb:
			return ra < rb
		return a < b)
	var avail_w: float = maxf(get_viewport().get_visible_rect().size.x - 64.0, 320.0)
	var r: float = clampf(avail_w / 8.0, 30.0, 96.0)   # 5 列总宽 = 8r
	var sq3 := sqrt(3.0)
	var card_r: float = r * 0.96
	var max_x := 0.0
	var max_y := 0.0
	for i in ids.size():
		var id: String = ids[i]
		var col := i % 5
		var row := int(i / float(5))
		var cx := r + float(col) * 1.5 * r
		var cy := r + sq3 * r * (float(row) + (0.5 if col % 2 == 1 else 0.0))
		var card := HexCard.new(DataRegistry.get_hero(id), id, card_r)
		card.position = Vector2(cx - card_r, cy - sq3 * card_r * 0.5)
		card.clicked.connect(_toggle)
		host.add_child(card)
		_btns[id] = card
		max_x = maxf(max_x, cx + r)
		max_y = maxf(max_y, cy + sq3 * r * 0.5)
	host.custom_minimum_size = Vector2(max_x, max_y)
	host.size = Vector2(max_x, max_y)

# 触屏拖动滚动英雄池（模拟器/手机上原生触摸拖动不总生效，与普通模式同处理）
func _input(ev: InputEvent) -> void:
	if _pool_scroll == null or not _pool_scroll.is_visible_in_tree():
		return
	if ev is InputEventScreenTouch:
		var st := ev as InputEventScreenTouch
		if st.pressed:
			_pool_touch_down = _pool_scroll.get_global_rect().has_point(st.position)
		else:
			_pool_touch_down = false
	elif _pool_touch_down and ev is InputEventScreenDrag:
		var sd := ev as InputEventScreenDrag
		_pool_scroll.scroll_vertical = int(_pool_scroll.scroll_vertical - sd.relative.y)

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
			(_btns[id] as HexCard).set_selected(false)
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
		(_btns[id] as HexCard).set_selected(_cur().has(id))
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
	GameState.dual_control = true     # 自由部署双控：敌方回合也由玩家操控(不跑 AI)
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
