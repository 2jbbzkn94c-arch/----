class_name Menu
extends Control
## 选卡界面（对战前派遣英雄上阵）。
## 玩家从卡池中挑选 3 名英雄（参照《酒馆纷争》轮流派遣），敌方自动随选 3 名。

var _selected: Array[String] = []
var _card_buttons: Dictionary = {}   # hero_id -> Button
var _pick_label: Label
var _start_btn: Button
var _desc_label: Label
var _detail_label: Label
var _tooltip: PanelContainer
var _tooltip_box: VBoxContainer
var _deck_slot_labels: Dictionary = {}   # slot -> Label

const PICK_COUNT := 8   # 整支队伍人数上限（前 3 名上阵，其余为替补）
const MIN_PICK := 5     # 至少选择 5 名英雄
const DEPLOY_COUNT := 3

const RULES_TEXT := "《酒馆纷争》玩法说明\n\n一、目标与胜负\n· 你和对手各有一支队伍：3 名首发上场，其余在替补席待命。\n· 一方累计阵亡 3 名英雄（含替补）即判负。\n· 若同一时刻双方都达到 3 名阵亡（同归于尽），判对方负、你获胜。\n\n二、开局流程\n· 普通模式：先组成阵容（选 5-8 名，前 3 名首发、其余替补）→ 开战后轮流上首发。\n· 竞技场模式：开局进入“2 选 1 选人”，你挑 4 次、敌方也会把没选的英雄给你（每队最终各 8 名），再轮流上首发。\n· 开局会提示本局先手：先手方先上首发，开战后也先行动。\n\n三、回合怎么进行\n· 每人一回合内：移动一次 + 攻击一次；“后勤”单位不能主动攻击。\n· 先手方行动完 → 对方行动 → 双方都完成才算满 1 回合。\n· 点击「结束回合」结束自己的回合；每回合限时 90 秒，超时自动结束。\n\n四、基础数值\n· 移动力默认 2（带「疾行」+1）；射程：近战 1、远程 2。\n· 攻击力会受增益/状态影响；远程单位身边紧邻敌人时攻击降为 1。\n\n五、阵亡与替补\n· 英雄阵亡留下墓碑；替补只能落在自己出生区或本方墓碑（不能落对方墓碑）。\n· 同时死多人时会逐个替补。\n· 第 11 回合起进入“烧血”阶段：每当你方回合结束结算一次，扣血 = 当前回合数 - 10\n  （第 11 回合扣 1、第 12 回合扣 2……），拖得越久越快。\n\n六、关键词（卡面 <xxx>）\n· 远程：无贴身敌人时射程为 2；有敌人紧邻时攻击降为 1。\n· 嘲讽：攻击范围内有带「嘲讽」的敌方时，只能先打它。\n· 疾行：移动力 +1。\n· 后勤：不能主动攻击（但会反击），只提供支援/光环。\n· 替补：替补登场时触发其后效果。\n· 渗透：移动可穿过敌方单位与障碍物，但不能停留。\n\n七、状态效果（卡面 [xxx]，同类不叠加，回合结束解除）\n· 猛毒：每个回合开始受 1 点伤害，无法解除。\n· 重伤：受到的伤害 +1。\n· 麻痹：攻击力 -1（至少为 0）。\n· 冰冻：移动力 -1（至少为 0）。\n· 沉默：不能触发非关键词技能。\n· 眩晕：不能移动/攻击/反击/触发技能。\n· 圣盾：抵挡一次受到的伤害，生效后解除。\n\n八、战场注意\n· 障碍物只能靠直接攻击打掉耐久（每次 -1；伐木工攻击障碍额外 -99），技能不再作用于障碍。\n· 炸弹：炸弹人放置；其他单位停留/经过会爆炸受 5 点伤害。\n· 增益道具拾取即生效；金矿永久提升攻击与生命上限。"

var _help_overlay: Control = null   # 游戏说明弹窗

func _ready() -> void:
	_build()

func _build() -> void:
	# 背景：酒馆木地板 + 轻微压暗增强卡片对比（两层都不接收鼠标）
	var bg := WoodFloor.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.22)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 40)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	add_child(margin)
	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "组建你的阵容"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_pick_label = Label.new()
	_pick_label.add_theme_font_size_override("font_size", 18)
	_pick_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_pick_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_pick_label)

	_desc_label = Label.new()
	_desc_label.add_theme_font_size_override("font_size", 14)
	_desc_label.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_desc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_desc_label.add_theme_constant_override("outline_size", 4)
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_desc_label)

	# 卡组缓存：3 个卡组槽（保存/读取），放顶部始终可见
	var deck_row := Label.new()
	deck_row.text = "自备卡组（可存 3 组，关游戏不丢）："
	deck_row.add_theme_font_size_override("font_size", 14)
	deck_row.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	vbox.add_child(deck_row)
	for slot in [1, 2, 3]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(row)
		var nl := Label.new()
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.size_flags_vertical = Control.SIZE_EXPAND_FILL
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.custom_minimum_size = Vector2(40, 30)
		row.add_child(nl)
		_deck_slot_labels[slot] = nl
		var save_b := Button.new()
		save_b.text = "保存"
		save_b.custom_minimum_size = Vector2(70, 32)
		save_b.pressed.connect(_save_current_deck.bind(slot))
		row.add_child(save_b)
		var load_b := Button.new()
		load_b.text = "读取"
		load_b.custom_minimum_size = Vector2(70, 32)
		load_b.pressed.connect(_load_deck.bind(slot))
		row.add_child(load_b)

	vbox.add_child(_spacer(10))

	# 卡池：固定 7 列放大卡面，放入滚动容器（桌面滚轮 / 安卓触摸滑动）
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.gui_input.connect(_on_pool_scroll_input)
	_pool_scroll = scroll
	vbox.add_child(scroll)
	var hex_host := Control.new()
	hex_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hex_host)
	_build_hex_pool(hex_host)

	_detail_label = Label.new()
	_detail_label.custom_minimum_size = Vector2(0, 118)
	_detail_label.add_theme_font_size_override("font_size", 13)
	_detail_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hex_host.add_child(_detail_label)
	_detail_label.position = Vector2(10, _hex_pool_size.y + 6)

	vbox.add_child(_spacer(16))

	# AI 难度选择
	var diff_box := HBoxContainer.new()
	diff_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_box.add_theme_constant_override("separation", 10)
	vbox.add_child(diff_box)
	var diff_label := Label.new()
	diff_label.text = "AI 难度："
	diff_label.add_theme_font_size_override("font_size", 16)
	diff_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	diff_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diff_box.add_child(diff_label)
	var diff := OptionButton.new()
	diff.add_item("简单")
	diff.add_item("普通")
	diff.add_item("困难")
	diff.select(GameState.ai_difficulty)
	diff.custom_minimum_size = Vector2(160, 42)
	diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff.item_selected.connect(func(i: int): GameState.ai_difficulty = i)
	diff_box.add_child(diff)

	_start_btn = Button.new()
	_start_btn.text = "开始对战"
	_start_btn.add_theme_font_size_override("font_size", 20)
	_start_btn.custom_minimum_size = Vector2(0, 52)
	_start_btn.pressed.connect(_on_start)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_start_btn)

	# 底部按钮并排，节省纵向
	var btn_row := HBoxContainer.new()
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)
	var rand_btn := Button.new()
	rand_btn.text = "随机派遣"
	rand_btn.add_theme_font_size_override("font_size", 15)
	rand_btn.custom_minimum_size = Vector2(0, 44)
	rand_btn.pressed.connect(_on_random)
	rand_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(rand_btn)
	var test_btn := Button.new()
	test_btn.text = "自由部署（测试）"
	test_btn.add_theme_font_size_override("font_size", 15)
	test_btn.custom_minimum_size = Vector2(0, 44)
	test_btn.pressed.connect(_go_test_deploy)
	test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(test_btn)
	var arena_btn := Button.new()
	arena_btn.text = "竞技场模式"
	arena_btn.add_theme_font_size_override("font_size", 15)
	arena_btn.custom_minimum_size = Vector2(0, 44)
	arena_btn.pressed.connect(_go_arena)
	arena_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(arena_btn)
	var net_btn := Button.new()
	net_btn.text = "联机对战"
	net_btn.add_theme_font_size_override("font_size", 15)
	net_btn.custom_minimum_size = Vector2(0, 44)
	net_btn.pressed.connect(_go_net)
	net_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(net_btn)

	# 底部小按钮并排：游戏说明 / 复制诊断信息
	var help_row := HBoxContainer.new()
	help_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_row.add_theme_constant_override("separation", 12)
	vbox.add_child(help_row)
	var help_btn := Button.new()
	help_btn.text = "游戏说明"
	help_btn.add_theme_font_size_override("font_size", 15)
	help_btn.custom_minimum_size = Vector2(0, 40)
	help_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_btn.pressed.connect(_open_help)
	help_row.add_child(help_btn)
	var diag_btn := Button.new()
	diag_btn.text = "复制诊断信息"
	diag_btn.add_theme_font_size_override("font_size", 15)
	diag_btn.custom_minimum_size = Vector2(0, 40)
	diag_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diag_btn.pressed.connect(_copy_diagnostics)
	help_row.add_child(diag_btn)

	_build_tooltip()
	_update_ui()

var _hex_pool_size := Vector2.ZERO
var _pool_scroll: ScrollContainer = null   # 英雄卡池滚动容器（触摸滑动用）
const _DETAIL_H := 130.0   # 卡池下方详情预留区高度（随卡池一起滚动可见）

# 英雄卡池：odd-q 蜂窝排布（与棋盘同一套公式：列间距1.5r、奇数列下移半行，
# 六边形边对边贴紧连成蜂窝）。固定 7 列、卡面放大；超高时滚动容器出现滚动条。
func _build_hex_pool(host: Control) -> void:
	var ids: Array = DataRegistry.heroes.keys()
	var cols := 7
	var avail_w: float = maxf(get_viewport().get_visible_rect().size.x - 56.0, 340.0)
	# 半径：让 7 列蜂窝（总宽 = 2r + 6*1.5r = 11r）尽量宽大，但不超过上限
	var r: float = clampf(avail_w / 11.0, 30.0, 96.0)
	var sq3 := sqrt(3.0)
	var per := int(ceil(float(ids.size()) / float(cols)))
	var total_w := 11.0 * r
	_hex_pool_size = Vector2(total_w, float(per + 1) * sq3 * r)
	host.custom_minimum_size = Vector2(total_w, _hex_pool_size.y + _DETAIL_H)
	host.size = Vector2(total_w, _hex_pool_size.y + _DETAIL_H)
	_card_buttons.clear()
	var margin_x: float = max((avail_w - total_w) / 2.0, 0.0)
	var max_x := 0.0
	var max_y := 0.0
	for i in ids.size():
		var id: String = ids[i]
		var col := i % cols
		var row := int(i / float(cols))
		var cx := margin_x + r + float(col) * 1.5 * r
		var cy := r + sq3 * r * (float(row) + (0.5 if col % 2 == 1 else 0.0))
		var card := HexCard.new(DataRegistry.heroes[id], id, r)
		card.position = Vector2(cx - r, cy - sq3 * r * 0.5)
		card.hovered.connect(_on_hex_hovered)
		card.clicked.connect(_on_hex_clicked)
		host.add_child(card)
		_card_buttons[id] = card
		max_x = maxf(max_x, cx + r)
		max_y = maxf(max_y, cy + sq3 * r * 0.5)
	_hex_pool_size = Vector2(max_x, max_y)
	host.custom_minimum_size = Vector2(max_x, max_y + _DETAIL_H)
	host.size = Vector2(max_x, max_y + _DETAIL_H)

# 安卓/触屏：手指上下滑动滚动卡池；桌面鼠标滚轮由 ScrollContainer 原生处理。
func _on_pool_scroll_input(ev: InputEvent) -> void:
	if ev is InputEventScreenDrag and _pool_scroll != null:
		var sd := ev as InputEventScreenDrag
		_pool_scroll.scroll_vertical = maxi(_pool_scroll.scroll_vertical - int(sd.relative.y), 0)

func _on_hex_hovered(id: String) -> void:
	if id == "":
		_hide_tooltip()
	else:
		_show_detail(id)

func _on_hex_clicked(id: String) -> void:
	_on_card_toggled(id)
	_card_buttons[id].set_selected(_selected.has(id))

func _build_tooltip() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tpn := _make_panel(Color(0.08, 0.1, 0.16, 0.97))
	tpn.content_margin_left = 12.0
	tpn.content_margin_right = 12.0
	tpn.content_margin_top = 10.0
	tpn.content_margin_bottom = 10.0
	_tooltip.add_theme_stylebox_override("panel", tpn)
	layer.add_child(_tooltip)
	_tooltip_box = VBoxContainer.new()
	_tooltip_box.add_theme_constant_override("separation", 5)
	_tooltip.add_child(_tooltip_box)

# 属性表按“显示区”分行：名字/基础属性/技能描述/词条解释，区之间插一条居中短线。
# 每次悬停重建内容（面板无容器重排，重建能同时解决内容变化后的尺寸残留）。
func _set_tooltip_zones(zones: Array) -> void:
	for c in _tooltip_box.get_children():
		_tooltip_box.remove_child(c)
		c.queue_free()
	for i in zones.size():
		if i > 0:
			# 短线直接放 VBox：不撑满时靠左对齐，即“贴左边”的短分行线
			var sep := HSeparator.new()
			sep.custom_minimum_size = Vector2(140, 4)
			sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var lnsb := StyleBoxLine.new()
			lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
			lnsb.thickness = 1
			sep.add_theme_stylebox_override("separator", lnsb)
			_tooltip_box.add_child(sep)
		var lb := Label.new()
		lb.text = zones[i]
		lb.add_theme_font_size_override("font_size", 16)
		lb.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.custom_minimum_size = Vector2(240, 0)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tooltip_box.add_child(lb)

func _make_panel(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 0.85, 0.5)
	return sb

func _process(_delta: float) -> void:
	if _tooltip != null and _tooltip.visible:
		var vs := get_viewport().get_visible_rect().size
		var pos := get_viewport().get_mouse_position() + Vector2(14, 14)
		pos.x = min(pos.x, vs.x - _tooltip.size.x - 8)
		pos.y = min(pos.y, vs.y - _tooltip.size.y - 8)
		_tooltip.position = pos

func _hide_tooltip() -> void:
	if _tooltip:
		_tooltip.visible = false

func _spacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

func _on_card_toggled(id: String) -> void:
	_show_detail(id)
	if _selected.has(id):
		_selected.erase(id)
	else:
		if _selected.size() >= PICK_COUNT:
			# 达到上限：提示并忽略
			_desc_label.text = "最多选择 %d 名英雄。" % PICK_COUNT
			_card_buttons[id].set_selected(false)
			_update_ui()
			return
		_selected.append(id)
	_update_ui()

func _show_detail(id: String) -> void:
	var def: DataRegistry.HeroDef = DataRegistry.heroes[id]
	# 各区文本由 DataRegistry.hero_info_zones 统一生成（与战斗内属性浮层同一套格式）
	var zones := DataRegistry.hero_info_zones(def)
	if _tooltip_box != null:
		_set_tooltip_zones(zones)
		# 面板直接挂在 CanvasLayer 下无容器重排：内容变化后重置到新内容的最小尺寸，
		# 避免先悬停过长描述英雄把面板撑高、之后短描述英雄底部残留留白。
		_tooltip.reset_size()
		_tooltip.visible = true
	else:
		_detail_label.text = "\n".join(zones)

func _update_ui() -> void:
	_pick_label.text = "已选 %d / %d（最少 %d）" % [_selected.size(), PICK_COUNT, MIN_PICK]
	_start_btn.disabled = _selected.size() < MIN_PICK
	for id in _card_buttons.keys():
		_card_buttons[id].set_selected(_selected.has(id))
	_refresh_deck_slots()
	if _selected.size() == 0:
		_desc_label.text = "点击卡牌，挑选 %d-%d 名英雄组成阵容（前 %d 名上阵，其余替补）。" % [MIN_PICK, PICK_COUNT, DEPLOY_COUNT]
	else:
		var names: Array[String] = []
		for id in _selected:
			names.append(DataRegistry.heroes[id].display_name)
		_desc_label.text = "阵容： " + "、 ".join(names)

func _on_random() -> void:
	_selected = _random_full_deck()
	_update_ui()

# 随机挑一整队 PICK_COUNT 名不重复英雄 —— 「随机选人」与"卡组不足 5 人时兜底"共用
func _random_full_deck() -> Array[String]:
	var pool: Array = DataRegistry.heroes.keys()
	pool.shuffle()
	var out: Array[String] = []
	for i in PICK_COUNT:
		out.append(pool[i])
	return out

func _on_start() -> void:
	if _selected.size() < MIN_PICK:
		return
	# 敌方卡组人数独立于玩家：随机 5-8 人
	var want := randi_range(MIN_PICK, PICK_COUNT)
	# 敌方按"机制协同"组建有配合的阵容，而非单纯按稀有度/数值
	var enemy := _synergy_pick(want)
	# 首发优先：带 <替补> 标签的英雄（梅林/波盾/太阳斩/猎颅者）技能只在替补登场时触发，
	# 自动排到卡组末尾（进替补席），保证前 3 名 = 首发型英雄。
	var starts: Array = []
	var bench: Array = []
	for id in _selected:
		if DataRegistry.heroes[id].skills.has(DataRegistry.Skill.BENCH):
			bench.append(id)
		else:
			starts.append(id)
	var ordered: Array = starts + bench
	GameState.set_decks(ordered, enemy)
	GameState.clear_placement()   # 普通模式用正常部署，不沿用"自由部署"放置，避免选人异常
	GameState.no_death_limit = false   # 正式模式用 3 人判负规则
	GameState.arena_mode = false
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# 英雄强度打分（单体基准，协同另行加分）
func _hero_strength(id: String) -> float:
	# 单体评分唯一实现在 DataRegistry.hero_strength()（避免两处公式漂移）
	return DataRegistry.hero_strength(id)

# 两英雄之间的协同分（取自共享知识库 DataRegistry.SYNERGY）
func _synergy_bonus(a: String, b: String) -> float:
	return DataRegistry.synergy_bonus(a, b)

# 已选卡组的"机制协同评分"
func _synergy_score(deck: Array) -> float:
	var s := 0.0
	for i in deck.size():
		for j in range(i + 1, deck.size()):
			s += _synergy_bonus(deck[i], deck[j])
	return s

# 按协同随机组建敌方卡组：轮盘权重抽取，每次选"单体强度+与已选协同"作为权重。
# 强/有配合的英雄权重更高（被抽中概率更大），但每次真正随机，不会总是同一批。
func _synergy_pick(want: int) -> Array:
	var cand := {}
	for id in DataRegistry.heroes.keys():
		cand[id] = true
	var chosen: Array = []
	while chosen.size() < want and cand.size() > 0:
		var wins: Array[float] = []
		var ids: Array = []
		var total := 0.0
		for id in cand.keys():
			var sc := _hero_strength(id)
			for c in chosen:
				sc += _synergy_bonus(c, id)
			sc += DataRegistry.role_balance_bonus(chosen, id)   # 职能配比：缺坦克/输出/功能/替补适当加分
			var w := maxf(sc, 0.0) + 1.0   # 权重下限为1，保证任何英雄都有机会
			wins.append(w)
			ids.append(id)
			total += w
		var r := randf() * total
		var acc := 0.0
		var best_id: String = ids[0]
		for i in ids.size():
			acc += wins[i]
			if acc >= r:
				best_id = ids[i]
				break
		chosen.append(best_id)
		cand.erase(best_id)
	return chosen

# ---- 卡组缓存 ----
func _save_current_deck(slot: int) -> void:
	if _selected.size() < MIN_PICK:
		_desc_label.text = "最少选择 %d 名英雄再保存卡组。" % MIN_PICK
		return
	DeckStore.save_deck(slot, _selected)
	_desc_label.text = "已保存到卡组 %d。" % slot
	_refresh_deck_slots()

func _load_deck(slot: int) -> void:
	var ids: Array = DeckStore.load_deck(slot)
	if ids.size() < MIN_PICK:
		# 普通模式：卡组槽不足 5 人（旧档/半存卡组）→ 自动随机选 8 名英雄顶上，不再拒绝读取
		_selected = _random_full_deck()
		_update_ui()
		_desc_label.text = "卡组 %d 不足 %d 人，已自动随机选满 %d 名英雄。" % [slot, MIN_PICK, PICK_COUNT]
		return
	_selected.clear()
	for id in ids:
		_selected.append(id)
	_update_ui()
	_refresh_deck_slots()
	_desc_label.text = "已读取卡组 %d。" % slot

func _refresh_deck_slots() -> void:
	for slot in _deck_slot_labels.keys():
		var lbl: Label = _deck_slot_labels[slot]
		var names: Array = DeckStore.load_deck(slot)
		var txt := "卡组 %d：" % slot
		if names.size() == 0:
			txt += " 空"
		else:
			var ds: Array[String] = []
			for id in names:
				ds.append(DataRegistry.heroes[id].display_name)
			txt += "、" .join(ds)
		lbl.text = txt

func _go_test_deploy() -> void:
	get_tree().change_scene_to_file("res://scenes/QuickTest.tscn")

# 竞技场模式：无需预选队伍，进入对战后随机2选1构建双方卡组
func _go_arena() -> void:
	GameState.arena_mode = true
	GameState.no_death_limit = false   # 正式模式用 3 人判负规则
	GameState.clear_placement()   # 竞技场用随机2选1构建卡组，不沿用"自由部署"放置
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

# 联机对战：进入联机大厅（开房/加入）
func _go_net() -> void:
	NetBus.stop()
	GameState.reset_online()   # 进入大厅前清干净上次联机残留（连接/标志/卡组）
	get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")

# ---- 游戏说明弹窗 ----
func _open_help() -> void:
	if _help_overlay != null and is_instance_valid(_help_overlay):
		_help_overlay.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_help_overlay = overlay
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.12, 0.16, 0.99)
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	sb.set_border_width_all(2)
	sb.border_color = Color(1.0, 0.85, 0.5)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	overlay.add_child(panel)
	panel.size = Vector2(minf(vsize.x - 48, 640), vsize.y - 120)
	panel.position = Vector2((vsize.x - panel.size.x) / 2.0, 60)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "游戏说明"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)
	var body := Label.new()
	body.text = RULES_TEXT
	body.add_theme_font_size_override("font_size", 15)
	body.add_theme_color_override("font_color", Color(0.92, 0.93, 1.0))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(panel.size.x - 60, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(_close_help)
	vb.add_child(close)

func _close_help() -> void:
	if _help_overlay != null and is_instance_valid(_help_overlay):
		_help_overlay.queue_free()
	_help_overlay = null

# ---- 崩溃诊断：把引擎日志等现场信息复制到剪贴板 ----
# 玩家遇到问题(闪退/卡死/报错)后点此按钮 → 粘贴发给开发者即可定位。
func _copy_diagnostics() -> void:
	var lines: Array = []
	lines.append("【酒馆纷争 诊断信息】")
	lines.append("引擎: Godot %s" % Engine.get_version_info().get("string", "?"))
	lines.append("系统: %s %s" % [OS.get_name(), OS.get_version()])
	var vp := get_viewport()
	lines.append("窗口: %d x %d" % [int(vp.get_visible_rect().size.x), int(vp.get_visible_rect().size.y)])
	lines.append("存档目录: %s" % OS.get_user_data_dir())
	lines.append("")
	lines.append("===== 引擎日志(godot.log) 末尾 =====")
	var logs_dir := OS.get_user_data_dir().path_join("logs")
	var log_path := logs_dir.path_join("godot.log")
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f == null:
		lines.append("(未找到 %s)" % log_path)
	else:
		var raw: String = f.get_as_text()
		f.close()
		# 只取末尾 200 行，避免剪贴板过大
		var tail: Array = raw.split("\n")
		if tail.size() > 200:
			tail = tail.slice(tail.size() - 200)
		if tail.size() == 0:
			lines.append("(日志为空)")
		else:
			lines.append_array(tail)
	# 附上最近的会话/崩溃日志文件（每次运行 Godot 都会生成时间戳日志；崩了重进后也仍能找到）
	var recent: Array = []
	var da := DirAccess.open(logs_dir)
	if da != null:
		da.list_dir_begin()
		var fn := da.get_next()
		while fn != "":
			if not da.current_is_dir() and fn.ends_with(".log") and fn != "godot.log":
				var p := logs_dir.path_join(fn)
				recent.append({ "name": fn, "path": p, "time": FileAccess.get_modified_time(p) })
			fn = da.get_next()
		da.list_dir_end()
	recent.sort_custom(func(a, b): return a["time"] > b["time"])
	for c in recent.slice(0, 4):
		lines.append("")
		lines.append("===== 历史会话日志: %s =====" % c["name"])
		var hf := FileAccess.open(c["path"], FileAccess.READ)
		if hf != null:
			var hraw: String = hf.get_as_text()
			hf.close()
			var htail: Array = hraw.split("\n")
			if htail.size() > 120:
				htail = htail.slice(htail.size() - 120)
			lines.append_array(htail)
	DisplayServer.clipboard_set("\n".join(lines))
	_desc_label.text = "诊断信息已复制到剪贴板（含引擎日志末尾 200 行 + 最近 %d 份历史会话日志）。请粘贴发给开发者。" % mini(recent.size(), 4)
