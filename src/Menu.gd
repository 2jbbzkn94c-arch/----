class_name Menu
extends Control
## 选卡界面（对战前派遣英雄上阵）。
## 玩家从卡池中挑选 3 名英雄（参照《酒馆纷争》轮流派遣），敌方自动随选 3 名。

var _selected: Array[String] = []
var _card_buttons: Dictionary = {}   # hero_id -> Button
var _start_btn: Button
var _detail_label: Label
var _tooltip: PanelContainer
var _tooltip_box: VBoxContainer
var _deck_tab_buttons: Dictionary = {}   # slot -> Button（卡组1/2/3 选择钮）
var _deck_host: Control = null           # 当前槽预览卡池宿主（整块重建）
var _deck_info: Label = null             # 当前槽状态提示行
var _deck_current_slot := 1              # 当前选中的卡组槽
var _sel_count: Label = null             # 卡组标题行右侧的"已选 N/8"计数

# —— 主菜单/普通模式 两屏切换 ——
var _main_view: Control = null   # 模式选择主菜单页
var _team_view: Control = null   # 普通模式（组队选人）页
var _main_msg: Label = null      # 主菜单页反馈文案（复制诊断等）
var _team_back_btn: Button = null

const PICK_COUNT := 8   # 整支队伍人数上限（前 3 名上阵，其余为替补）
const MIN_PICK := 5     # 至少选择 5 名英雄
const DEPLOY_COUNT := 3
const CARD_GAP_SCALE := 0.96   # 选人池卡牌绘制半径/间距半径：1.0=边贴边无空隙，调小=空隙增大

const RULES_TEXT := "《酒馆纷争》玩法说明\n\n一、目标与胜负\n· 你和对手各有一支队伍：3 名首发上场，其余在替补席待命。\n· 一方累计阵亡 3 名英雄（含替补）即判负。\n· 若同一时刻双方都达到 3 名阵亡（同归于尽），判对方负、你获胜。\n\n二、开局流程\n· 普通模式：先组成阵容（选 5-8 名，前 3 名首发、其余替补）→ 开战后轮流上首发。\n· 竞技场模式：开局进入“2 选 1 选人”，你挑 4 次、敌方也会把没选的英雄给你（每队最终各 8 名），再轮流上首发。\n· 开局会提示本局先手：先手方先上首发，开战后也先行动。\n\n三、回合怎么进行\n· 每人一回合内：先移动、后攻击（攻击后即不能再移动）；“后勤”单位不能主动攻击。\n· 先手方行动完 → 对方行动 → 双方都完成才算满 1 回合。\n· 点击「结束回合」结束自己的回合；每回合限时 90 秒，超时自动结束。\n\n四、基础数值\n· 移动力默认 2（带「疾行」+1）；射程：近战 1、远程 2。\n· 攻击力会受增益/状态影响；远程单位身边紧邻敌人时攻击降为 1。\n\n五、阵亡与替补\n· 英雄阵亡留下墓碑；替补只能落在自己出生区或本方墓碑（不能落对方墓碑）。\n· 同时死多人时会逐个替补。\n· 第 11 回合起进入“烧血”阶段：每当你方回合结束结算一次，扣血 = 当前回合数 - 10\n  （第 11 回合扣 1、第 12 回合扣 2……），拖得越久越快。\n\n六、关键词（卡面 <xxx>）\n· 远程：无贴身敌人时射程为 2；有敌人紧邻时攻击降为 1。\n· 嘲讽：攻击范围内有带「嘲讽」的敌方时，只能先打它。\n· 疾行：移动力 +1。\n· 后勤：不能主动攻击（但会反击），只提供支援/光环。\n· 替补：替补登场时触发其后效果。\n· 渗透：移动可穿过双方单位与障碍物，但不能停留。\n\n七、状态效果（卡面 [xxx]，同类不叠加，回合结束解除）\n· 猛毒：每个回合开始受 1 点伤害，无法解除。\n· 重伤：受到的伤害 +1。\n· 麻痹：攻击力 -1（至少为 0）。\n· 冰冻：移动力 -1（至少为 0）。\n· 沉默：不能触发非关键词技能。\n· 眩晕：不能移动/攻击/反击/触发技能。\n· 圣盾：抵挡一次受到的伤害，生效后解除。\n\n八、战场注意\n· 障碍物只能靠直接攻击打掉耐久（每次 -1；伐木工攻击障碍额外 -99），技能不再作用于障碍。\n· 炸弹：炸弹人放置；其他单位停留/经过会爆炸受 5 点伤害。\n· 增益道具拾取即生效；金矿：攻击+1（永久）、生命上限+3并回复3点血（仅黄金矿工可拾取）。"

var _help_overlay: Control = null   # 游戏说明弹窗

func _ready() -> void:
	_build()
	if GameState.net_edit_mode:
		_show_team_view()   # 联机大厅叠层打开：直接进选人页

# 联机大厅"编辑卡组"完成：复位标志、通知大厅刷新、销毁本叠层
func _on_edit_done() -> void:
	var lobby := get_parent()
	GameState.end_deck_edit()
	if lobby != null and is_instance_valid(lobby) and lobby.has_method("_on_editor_closed"):
		lobby.call("_on_editor_closed")
		queue_free()
	else:
		# 非叠层（异常残留标志）：回主菜单重新进入
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")

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

	# —— 两屏容器：主菜单（模式选择） / 普通模式（组队选人） ——
	_main_view = Control.new()
	_main_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_main_view)
	_team_view = Control.new()
	_team_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_team_view.visible = false
	add_child(_team_view)
	_build_main_menu()

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 40)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	_team_view.add_child(margin)
	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	# 1) 标题
	var title := Label.new()
	title.text = "编辑卡组（联机）" if GameState.net_edit_mode else "普通模式"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# 2) 英雄池：固定 7 列放大卡面，放入滚动容器（桌面滚轮 / 安卓触摸滑动），占弹性空间
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	# 禁用横向滚动：池宽按容器内宽排布不会超宽，杜绝左右滑动；纵向交给引擎原生（触屏拖动/滚轮均内置）
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pool_scroll = scroll
	vbox.add_child(scroll)
	var hex_host := Control.new()
	hex_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hex_host)
	_build_hex_pool(hex_host)

	_detail_label = Label.new()
	_detail_label.custom_minimum_size = Vector2(0, 96)
	_detail_label.add_theme_font_size_override("font_size", 13)
	_detail_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hex_host.add_child(_detail_label)
	_detail_label.position = Vector2(10, _hex_pool_size.y + 6)

	# 3) 卡组区：上部 = 标题行（右端显示"已选 N/8"）+ 卡组1/2/3 切换 + 右侧 清空；
	#    下部 = 当前卡组队伍预览（自动保存，与替补队伍同款一行小卡）。点卡组槽即切换编辑目标并载入。
	var deck_cap := HBoxContainer.new()
	deck_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(deck_cap)
	var cap_lb := Label.new()
	cap_lb.text = "自备卡组（自动保存，3 组）："
	cap_lb.add_theme_font_size_override("font_size", 14)
	cap_lb.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	deck_cap.add_child(cap_lb)
	var cap_space := Control.new()
	cap_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck_cap.add_child(cap_space)
	_sel_count = Label.new()
	_sel_count.add_theme_font_size_override("font_size", 14)
	_sel_count.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	_sel_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	deck_cap.add_child(_sel_count)

	var deck_bar := HBoxContainer.new()
	deck_bar.add_theme_constant_override("separation", 8)
	deck_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(deck_bar)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	deck_bar.add_child(tabs)
	for slot in [1, 2, 3]:
		var tab := Button.new()
		tab.text = "卡组 %d" % slot
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 34)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(_on_deck_tab.bind(slot))
		tabs.add_child(tab)
		_deck_tab_buttons[slot] = tab
	var clear_b := Button.new()
	clear_b.text = "清空"
	clear_b.custom_minimum_size = Vector2(76, 34)
	clear_b.pressed.connect(_on_deck_clear)
	deck_bar.add_child(clear_b)

	_deck_info = Label.new()
	_deck_info.add_theme_font_size_override("font_size", 13)
	_deck_info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_deck_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_deck_info)
	_deck_host = Control.new()
	_deck_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_deck_host)

	# 4) AI 难度 与 随机派遣 并列一排
	var option_row := HBoxContainer.new()
	option_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option_row.add_theme_constant_override("separation", 12)
	vbox.add_child(option_row)
	var diff_box := VBoxContainer.new()
	diff_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	diff_box.add_theme_constant_override("separation", 0)
	option_row.add_child(diff_box)
	var diff_label := Label.new()
	diff_label.text = "AI 难度"
	diff_label.add_theme_font_size_override("font_size", 13)
	diff_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	diff_box.add_child(diff_label)
	var diff := OptionButton.new()
	diff.add_item("简单")
	diff.add_item("普通")
	diff.add_item("困难")
	diff.select(GameState.ai_difficulty)
	diff.custom_minimum_size = Vector2(0, 36)
	diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diff.item_selected.connect(func(i: int): GameState.ai_difficulty = i)
	diff_box.add_child(diff)

	# 随机派遣
	var rand_btn := Button.new()
	rand_btn.text = "随机派遣"
	rand_btn.add_theme_font_size_override("font_size", 15)
	rand_btn.custom_minimum_size = Vector2(150, 36)
	rand_btn.pressed.connect(_on_random)
	rand_btn.size_flags_vertical = Control.SIZE_SHRINK_END
	option_row.add_child(rand_btn)

	# 5) 开始对战（联机大厅编辑模式 = "完成编辑"）
	_start_btn = Button.new()
	if GameState.net_edit_mode:
		_start_btn.text = "完成编辑"
		_start_btn.pressed.connect(_on_edit_done)
	else:
		_start_btn.text = "开始对战"
		_start_btn.pressed.connect(_on_start)
	_start_btn.add_theme_font_size_override("font_size", 20)
	_start_btn.custom_minimum_size = Vector2(0, 50)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_start_btn)

	# 6) 返回（整行大按钮）：单机=回主菜单；联机编辑=回联机大厅
	var back_btn := Button.new()
	back_btn.text = "返回联机大厅" if GameState.net_edit_mode else "返回主菜单"
	back_btn.add_theme_font_size_override("font_size", 18)
	back_btn.custom_minimum_size = Vector2(0, 46)
	back_btn.pressed.connect(_on_edit_done if GameState.net_edit_mode else _show_main_menu)
	back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(back_btn)
	_team_back_btn = back_btn

	_build_tooltip()
	_update_ui()

	# 右上角音效音量调节（喇叭按钮 + 滑条弹层，两页共用）
	var volume := VolumeControl.new()
	add_child(volume)
	volume.place_top_right(get_viewport().get_visible_rect().size, 8.0, 6.0)
	_show_main_menu()

# —— 主菜单（模式选择页）——
func _build_main_menu() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_top", 60)
	margin.add_theme_constant_override("margin_bottom", 80)
	margin.add_theme_constant_override("margin_left", 90)
	margin.add_theme_constant_override("margin_right", 90)
	_main_view.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "酒馆纷争"
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("outline_size", 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	var sub := Label.new()
	sub.text = "六边形回合制对战"
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)
	vbox.add_child(_spacer(8))

	var add_mode_btn := func(txt: String, cb: Callable) -> void:
		var b := Button.new()
		b.text = txt
		b.add_theme_font_size_override("font_size", 22)
		b.custom_minimum_size = Vector2(0, 58)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(cb)
		vbox.add_child(b)
	add_mode_btn.call("普通模式", _show_team_view)
	add_mode_btn.call("竞技场模式", _go_arena)
	add_mode_btn.call("联机模式", _go_net)
	add_mode_btn.call("自由部署（测试）", _go_test_deploy)
	add_mode_btn.call("游戏说明", _open_help)
	add_mode_btn.call("复制诊断信息", _copy_diagnostics)
	var quit_btn := Button.new()
	quit_btn.text = "退出游戏"
	quit_btn.add_theme_font_size_override("font_size", 18)
	quit_btn.custom_minimum_size = Vector2(0, 46)
	quit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(quit_btn)
	_main_msg = Label.new()
	_main_msg.add_theme_font_size_override("font_size", 14)
	_main_msg.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_main_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main_msg.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(_main_msg)

func _show_main_menu() -> void:
	_main_view.visible = true
	_team_view.visible = false
	if _team_back_btn:
		_team_back_btn.grab_focus()

func _show_team_view() -> void:
	_main_view.visible = false
	_team_view.visible = true
	_deck_current_slot = GameState.last_deck_slot
	if _selected.size() == 0:
		_load_deck(_deck_current_slot)   # 进入自动载入上次编辑的卡组（含空槽提示）
	else:
		_update_ui()
	_refresh_deck_slots()

var _hex_pool_size := Vector2.ZERO
var _pool_scroll: ScrollContainer = null   # 英雄卡池滚动容器（纵向原生滚动）
const _DETAIL_H := 130.0   # 卡池下方详情预留区高度（随卡池一起滚动可见）

# 英雄卡池：odd-q 蜂窝排布（与棋盘同一套公式：列间距1.5r、奇数列下移半行，
# 六边形边对边贴紧连成蜂窝）。每行 5 张放大卡面，超高时滚动容器出现滚动条。
func _build_hex_pool(host: Control) -> void:
	# 卡池按稀有度排：白(低)→金→紫→虹(高)，同稀有按 hero_id 排——保证初始界面顺序固定，
	# 新增英雄无论加在角色列表的哪个位置都落到对应稀有度区段。
	var ids: Array = DataRegistry.heroes.keys()
	ids.sort_custom(func(a: String, b: String):
		var da := DataRegistry.get_hero(a)
		var db := DataRegistry.get_hero(b)
		var ra := da.rarity if da != null else 0
		var rb := db.rarity if db != null else 0
		if ra != rb:
			return ra < rb
		return a < b)
	var cols := 5
	# 可用宽按滚动容器内宽计(视口宽 - 左右边距 24*2 - 少量余量)，保证池宽 ≤ 容器宽，横向永不出滚动条
	var avail_w: float = maxf(get_viewport().get_visible_rect().size.x - 64.0, 320.0)
	# 半径：让 5 列蜂窝（总宽 = 2r + 4*1.5r = 8r）尽量宽大
	var r: float = clampf(avail_w / 8.0, 30.0, 96.0)
	var sq3 := sqrt(3.0)
	var per := int(ceil(float(ids.size()) / float(cols)))
	var total_w := 8.0 * r
	_hex_pool_size = Vector2(total_w, float(per + 1) * sq3 * r)
	host.custom_minimum_size = Vector2(total_w, _hex_pool_size.y + _DETAIL_H)
	host.size = Vector2(total_w, _hex_pool_size.y + _DETAIL_H)
	_card_buttons.clear()
	# 卡片绘制半径比蜂窝间距半径略小（CARD_GAP_SCALE）：六边形间留出一点小空隙，
	# 避免边贴边让相邻描边重叠、选中高亮被邻卡盖住；图标溢出也落在空隙里。
	var card_r: float = r * CARD_GAP_SCALE
	var margin_x: float = max((avail_w - total_w) / 2.0, 0.0)
	var max_x := 0.0
	var max_y := 0.0
	for i in ids.size():
		var id: String = ids[i]
		var col := i % cols
		var row := int(i / float(cols))
		var cx := margin_x + r + float(col) * 1.5 * r
		var cy := r + sq3 * r * (float(row) + (0.5 if col % 2 == 1 else 0.0))
		var card := HexCard.new(DataRegistry.heroes[id], id, card_r)
		card.position = Vector2(cx - card_r, cy - sq3 * card_r * 0.5)
		card.hovered.connect(_on_hex_hovered)
		card.clicked.connect(_on_hex_clicked)
		host.add_child(card)
		_card_buttons[id] = card
		max_x = maxf(max_x, cx + r)
		max_y = maxf(max_y, cy + sq3 * r * 0.5)
	_hex_pool_size = Vector2(max_x, max_y)
	host.custom_minimum_size = Vector2(max_x, max_y + _DETAIL_H)
	host.size = Vector2(max_x, max_y + _DETAIL_H)

# 触屏/滚轮纵向滚动交给 ScrollContainer 引擎原生处理（4.x 自带触屏拖动与惯性，
# 且事件不会因起点在卡片上而失效）；本页只禁用了横向滚动避免左右滑。

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
			_flash("最多选择 %d 名英雄。" % PICK_COUNT)
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
	_start_btn.disabled = false   # 人数不足时仍可点开始，由 _on_start 弹框说明
	for id in _card_buttons.keys():
		_card_buttons[id].set_selected(_selected.has(id))
	if _sel_count != null:
		_sel_count.text = "已选 %d / %d" % [_selected.size(), PICK_COUNT]
	_auto_sync()
	_refresh_deck_slots()

# 阵容任一变化 → 自动写回当前卡组槽（内容相同则不重复写盘）
func _auto_sync() -> void:
	var stored: Array = DeckStore.load_deck(_deck_current_slot)
	var cur: Array = _selected.duplicate()
	if stored != cur:
		DeckStore.save_deck(_deck_current_slot, cur)

# 底部提示已按需求移除（不再显示"已读取卡组/引导"等字样），保留空实现以便调用点不动。
func _flash(_msg: String) -> void:
	pass

func _refresh_banner() -> void:
	if _detail_label != null and is_instance_valid(_detail_label):
		_detail_label.text = ""

func _on_random() -> void:
	_selected = _random_full_deck()
	_update_ui()

# 随机挑一整队 PICK_COUNT 名不重复英雄（随机派遣用）
func _random_full_deck() -> Array[String]:
	var pool: Array = DataRegistry.heroes.keys()
	pool.shuffle()
	var out: Array[String] = []
	for i in PICK_COUNT:
		out.append(pool[i])
	return out

func _on_start() -> void:
	if _selected.size() < MIN_PICK:
		_show_need_more_dialog()
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

# 开始对战但人数不足：弹框说明（不自动随机补足）
func _show_need_more_dialog() -> void:
	var d := AcceptDialog.new()
	d.title = "阵容不足"
	d.dialog_text = "至少需要 %d 名英雄才能开始对战（当前 %d 名）。\n请回到卡池继续挑选，或点「随机派遣」。" % [MIN_PICK, _selected.size()]
	d.ok_button_text = "知道了"
	d.confirmed.connect(d.queue_free)
	add_child(d)
	d.popup_centered()

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

# ---- 卡组（自动保存）----
# 点卡组槽 = 切换编辑目标并原样载入（少于 5 人也按保存的队伍载入，开战时再校验）
func _on_deck_tab(slot: int) -> void:
	_deck_current_slot = slot
	GameState.last_deck_slot = slot
	_load_deck(slot)
	_refresh_deck_slots()   # 统一刷新 tab 高亮与该槽预览

func _on_deck_clear() -> void:
	_selected.clear()
	_update_ui()   # 同步取消英雄池高亮、清空槽（自动保存）、刷新预览

func _load_deck(slot: int) -> void:
	var ids: Array = DeckStore.load_deck(slot)
	_selected.clear()
	for id in ids:
		_selected.append(String(id))
	_update_ui()
	_refresh_deck_slots()

func _refresh_deck_slots() -> void:
	for slot in _deck_tab_buttons.keys():
		var tab: Button = _deck_tab_buttons[slot]
		tab.set_pressed_no_signal(slot == _deck_current_slot)
	# 清空旧预览后按当前槽重建
	if _deck_host:
		for c in _deck_host.get_children():
			_deck_host.remove_child(c)
			c.queue_free()
	var ids: Array = DeckStore.load_deck(_deck_current_slot)
	if ids.size() == 0:
		_deck_host.custom_minimum_size = Vector2.ZERO
		_deck_host.size = Vector2.ZERO
		_deck_info.visible = true
		_deck_info.text = "卡组 %d：空 —— 改动卡池阵容会自动保存到本槽。" % _deck_current_slot
		return
	# 有内容：只显示队伍小卡预览，不显示文字行
	_deck_info.visible = false
	_build_deck_preview(ids)

# 与替补队伍面板同款布局：所选卡组一行平顶蜂窝小卡（悬停看属性）
func _build_deck_preview(ids: Array) -> void:
	var avail: float = get_viewport().get_visible_rect().size.x - 80.0
	var n := maxi(ids.size(), 1)
	var r: float = minf(46.0, maxf(avail / (2.0 + float(n - 1) * 1.5), 18.0))
	var sq3 := sqrt(3.0)
	var col_step := 1.5 * r
	var row_step := sq3 * r
	var total_w := 2.0 * r + float(n - 1) * col_step
	var total_h := 2.0 * row_step
	_deck_host.custom_minimum_size = Vector2(total_w, total_h)
	_deck_host.size = Vector2(total_w, total_h)
	for i in ids.size():
		var hid: String = ids[i]
		var def := DataRegistry.get_hero(hid)
		if def == null:
			continue
		var cx := r + float(i) * col_step
		var cy := r + (row_step / 2.0 if i % 2 == 1 else 0.0)
		var card := HexCard.new(def, hid, r)
		card.position = Vector2(cx - r, cy - row_step / 2.0)
		card.hovered.connect(_on_hex_hovered)
		_deck_host.add_child(card)

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
	var note := "诊断信息已复制到剪贴板（含引擎日志末尾 200 行 + 最近 %d 份历史会话日志）。请粘贴发给开发者。" % mini(recent.size(), 4)
	if _main_msg != null and is_instance_valid(_main_msg) and _main_msg.is_visible_in_tree():
		_main_msg.text = note
	else:
		_flash(note)
