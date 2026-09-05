class_name Deploy
extends Control
## 开局部署选人：随机一方先手，双方交替各选 1 名上阵，各选满 3 人后开始对战。
## 玩家手动从我方卡池选；敌方由 AI 自动选。

const DEPLOY := 3

var player_pool: Array = []
var enemy_pool: Array = []
var player_deployed: Array = []
var enemy_deployed: Array = []
var current_side := 0   # 随机先手
var finished := false

var _turn_label: Label
var _status_label: Label
var _player_cards: Dictionary = {}   # id -> Button
var _enemy_cards: Dictionary = {}

func _ready() -> void:
	player_pool = GameState.player_deck.duplicate()
	enemy_pool = GameState.enemy_deck.duplicate()
	current_side = randi() % 2
	_build()
	_refresh()
	# 若敌方先手，稍作停顿后自动选
	if current_side == 1:
		_enemy_pick.call_deferred()

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(20, 30)
	vbox.size = Vector2(vsize.x - 40, vsize.y - 60)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	var title := Label.new()
	title.text = "开局选人（轮流部署）"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 18)
	_turn_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_turn_label)

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	vbox.add_child(_mk_pool_title("我方卡池（点击选出战）", Color(0.5, 0.85, 1.0)))
	vbox.add_child(_mk_pool_grid(true))
	vbox.add_child(_mk_pool_title("敌方卡池（AI 自动选）", Color(1.0, 0.5, 0.5)))
	vbox.add_child(_mk_pool_grid(false))

func _mk_pool_title(t: String, color: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", color)
	return l

func _mk_pool_grid(is_player: bool) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pool: Array = player_pool if is_player else enemy_pool
	for hid in pool:
		var b := Button.new()
		var def := DataRegistry.get_hero(hid)
		b.text = def.display_name
		b.add_theme_font_size_override("font_size", 14)
		b.custom_minimum_size = Vector2(0, 42)
		b.pressed.connect(_on_player_pick.bind(hid) if is_player else func(): pass)
		if is_player:
			_player_cards[hid] = b
		else:
			_enemy_cards[hid] = b
		grid.add_child(b)
	return grid

func _on_player_pick(id: String) -> void:
	if finished or current_side != 0:
		return
	if not player_pool.has(id):
		return
	player_pool.erase(id)
	player_deployed.append(id)
	if player_deployed.size() == DEPLOY:
		_status_label.text = "我方已选满 3 名。"
		if enemy_deployed.size() == DEPLOY:
			_start_battle()
			return
		_pass_to_enemy()
		return
	_pass_to_enemy()

func _pass_to_enemy() -> void:
	current_side = 1
	_refresh()
	_enemy_pick.call_deferred()

func _enemy_pick() -> void:
	if finished:
		return
	if enemy_pool.size() > 0 and enemy_deployed.size() < DEPLOY:
		var hid: String = enemy_pool.pop_front()
		enemy_deployed.append(hid)
		if enemy_deployed.size() == DEPLOY and player_deployed.size() == DEPLOY:
			_start_battle()
			return
		# 交回我方（若我方还没选满）
		current_side = 0
		if player_deployed.size() == DEPLOY:
			# 我方先满，但敌方还需补选（不应发生，因交替）
			pass
		_refresh()

func _refresh() -> void:
	_turn_label.text = ("轮到我方选择" if current_side == 0 else "轮到敌方选择") + "   场次：我方 %d/3 · 敌方 %d/3" % [player_deployed.size(), enemy_deployed.size()]
	for hid in _player_cards.keys():
		var b: Button = _player_cards[hid]
		var used := player_deployed.has(hid) or not player_pool.has(hid)
		b.disabled = used or current_side != 0 or finished
		b.text = DataRegistry.get_hero(hid).display_name + (" ✓" if used and player_deployed.has(hid) else "")
	for hid in _enemy_cards.keys():
		var eb: Button = _enemy_cards[hid]
		var eused := enemy_deployed.has(hid) or not enemy_pool.has(hid)
		eb.disabled = true
		eb.text = DataRegistry.get_hero(hid).display_name + (" ✓" if eused and enemy_deployed.has(hid) else "")

func _start_battle() -> void:
	if finished:
		return
	finished = true
	# 已选 3 名排前，其余作替补
	GameState.player_deck = player_deployed + player_pool
	GameState.enemy_deck = enemy_deployed + enemy_pool
	GameState.clear_placement()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
