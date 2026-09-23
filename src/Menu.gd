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
const MENU_BTN_W := 400.0   # 主菜单按钮长度（宽度）；原来顶满整行 540，改窄并居中
const CARD_GAP_SCALE := 0.96   # 选人池卡牌绘制半径/间距半径：1.0=边贴边无空隙，调小=空隙增大
# 封面背景候选：按顺序取【第一个能加载的】——换封面只需把想用的那张挪到最前。
# 源文件在 assets/美术资源/背景/（*.svg 用 tools/RenderCover 出 PNG；*.jpg 是直接投放的位图）。
# 缺图自动退回纯色底（WoodFloor）。
const COVER_BG_CANDIDATES := [
	"res://assets/美术资源/背景/界面背景_六角地砖.jpg",   # 六角地砖 + 灯笼/骰子/剑盾（暗调，UI 界面用）
	"res://assets/美术资源/背景/酒桌封面.png",   # 方案B：酒桌俯视，桌面刻着六边形棋盘
	"res://assets/美术资源/背景/酒馆封面.png",   # 方案A：酒馆内景·吧台
]

const RULES_TEXT := "《酒馆纷争》玩法说明\n\n一、目标与胜负\n· 你和对手各有一支队伍：3 名首发上场，其余在替补席待命。\n· 一方累计阵亡 3 名英雄（含替补）即判负。\n· 若同一时刻双方都达到 3 名阵亡（同归于尽），判对方负、你获胜。\n\n二、开局流程\n· 普通模式：先在编辑页组成阵容并保存到卡组槽（选 5-8 名，前 3 名首发、其余替补）；开战后在战斗内弹出“选择卡组”，从 3 个已存卡组里挑一个出战（也可点「随机英雄」）→ 再轮流上首发。\n· 竞技场模式：开局进入“2 选 1 选人”，你挑 4 次、敌方也会把没选的英雄给你（每队最终各 8 名），再轮流上首发。\n· 开局会提示本局先手：先手方先上首发，开战后也先行动。\n\n三、回合怎么进行\n· 每人一回合内：先移动、后攻击（攻击后即不能再移动）；“后勤”单位不能主动攻击。\n· 先手方行动完 → 对方行动 → 双方都完成才算满 1 回合。\n· 点击「结束回合」结束自己的回合；每回合限时 90 秒，超时自动结束。\n\n四、基础数值\n· 移动力默认 2（带「疾行」+1）；射程：近战 1、远程 2。\n· 攻击力会受增益/状态影响；远程单位身边紧邻敌人时攻击降为 1。\n\n五、阵亡与替补\n· 英雄阵亡留下墓碑；替补只能落在自己出生区或本方墓碑（不能落对方墓碑）。\n· 同时死多人时会逐个替补。\n· 第 11 回合起进入“烧血”阶段：每当你方回合结束结算一次，扣血 = 当前回合数 - 10\n  （第 11 回合扣 1、第 12 回合扣 2……），拖得越久越快。\n\n六、关键词（卡面 <xxx>）\n· 远程：无贴身敌人时射程为 2；有敌人紧邻时攻击降为 1。\n· 嘲讽：攻击范围内有带「嘲讽」的敌方时，只能先打它。\n· 疾行：移动力 +1。\n· 后勤：不能主动攻击（但会反击），只提供支援/光环。\n· 替补：替补登场时触发其后效果。\n· 渗透：移动可穿过双方单位与障碍物，但不能停留。\n\n七、状态效果（卡面 [xxx]，同类不叠加，回合结束解除）\n· 猛毒：双方任一回合开始时都受 1 点伤害，无法解除。\n· 重伤：受到的伤害 +1。\n· 麻痹：攻击力 -1（至少为 0）。\n· 冰冻：移动力 -1（至少为 0）。\n· 沉默：不能触发非关键词技能。\n· 眩晕：不能移动/攻击/反击/触发技能。\n· 圣盾：可抵挡一次受到的伤害，抵挡后解除。\n\n八、战场注意\n· 障碍物只能靠直接攻击打掉耐久（每次 -1；伐木工攻击障碍额外 -99），且主动打障碍物不会触发英雄技能；但技能在打敌人时“波及”到的障碍物（剑气穿透扫过、散射/爆炸的相邻范围）同样掉 1 点耐久。\n· 炸弹：炸弹人放置；其他单位停留在炸弹格上会爆炸受 5 点伤害（单纯经过不炸）。\n· 增益道具拾取即生效；金矿：攻击+1（永久）、生命上限+3并回复3点血（仅黄金矿工可拾取）。"

var _help_overlay: Control = null   # 游戏说明弹窗
var _stats_overlay: Control = null  # 对战统计弹窗

func _ready() -> void:
	_build()
	set_process_input(true)   # 触摸跟踪（轻点 vs 按住拖动池）
	if GameState.net_edit_mode:
		_show_team_view()   # 联机大厅叠层打开：直接进选人页

# 封面背景图：等比裁切铺满整屏（候选都缺图时返回 null，由纯色底兜底）
func _make_cover_bg() -> TextureRect:
	for path in COVER_BG_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var cover_rect := TextureRect.new()
		cover_rect.texture = tex
		cover_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		cover_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		cover_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		cover_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return cover_rect
	return null

# 竖向渐变遮罩：中段（按钮列/卡池背后）压暗保可读性，顶部标题与底部吧台留亮，
# 取代原来的 22% 平铺压暗——平铺压暗会把插画的吧台暖光一起吃掉。
func _make_cover_scrim() -> TextureRect:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.14, 0.34, 0.74, 0.90, 1.0])
	grad.colors = PackedColorArray([
		Color(0, 0, 0, 0.24),
		Color(0, 0, 0, 0.18),
		Color(0, 0, 0, 0.40),
		Color(0, 0, 0, 0.36),
		Color(0, 0, 0, 0.14),
		Color(0, 0, 0, 0.08),
	])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.0, 0.0)
	gt.fill_to = Vector2(0.0, 1.0)
	gt.width = 8
	gt.height = 256
	var scrim_rect := TextureRect.new()
	scrim_rect.texture = gt
	scrim_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scrim_rect.stretch_mode = TextureRect.STRETCH_SCALE
	scrim_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return scrim_rect

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
	# 背景：纯色木地板兜底 → 封面插画（酒馆内景）铺满 → 竖向渐变遮罩。
	# 三层都不接收鼠标。缺图时自动退回纯色底，不影响启动。
	var bg := WoodFloor.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var cover := _make_cover_bg()
	if cover != null:
		add_child(cover)
	add_child(_make_cover_scrim())

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
	#    池上方一行 = 筛选按钮 + 结果计数（筛选只影响显示，不影响已选卡组）
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 12)
	filter_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(filter_row)
	_filter_btn = Button.new()
	_filter_btn.text = "筛选"
	_filter_btn.custom_minimum_size = Vector2(0, 38)
	_filter_btn.add_theme_font_size_override("font_size", 16)
	_filter_btn.pressed.connect(_open_filter)
	filter_row.add_child(_filter_btn)
	_filter_info = Label.new()
	_filter_info.add_theme_font_size_override("font_size", 14)
	_filter_info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_filter_info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	filter_row.add_child(_filter_info)

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
	_pool_host = hex_host
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
	diff.add_item("噩梦")    # 第 4 档：RL 候选 AI + 训练权重（**英雄特化段也在同一份权重文件里**，见 src/Battle.gd）
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
	# 【2026-09-23 用户口径】`VolumeControl` 已从独立文件搬进 `src/HUD.gd` 当嵌套类（小功能不另起文件）
	#   ⇒ 这里按"外层类.嵌套类"取用（`HUD` 是全局类名，跨文件访问嵌套类就这么写）。
	var volume := HUD.VolumeControl.new()
	add_child(volume)
	volume.place_top_right(get_viewport().get_visible_rect().size, 8.0, 6.0)
	# 左上角版本号（发布日期；日期存自定义键 version_date,config/version 仅供 Godot 导出用）
	var ver := Label.new()
	var ver_str := str(ProjectSettings.get_setting("application/config/version_date", ""))
	ver.text = ver_str
	ver.add_theme_font_size_override("font_size", 14)
	ver.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	ver.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	ver.add_theme_constant_override("outline_size", 3)
	ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ver)
	ver.position = Vector2(18, 16)
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
	# 主标题字号：72（原 48）。描边同步放大到 9，否则字变大后黑边显得太细、压在背景上不清晰。
	title.add_theme_font_size_override("font_size", 72)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	title.add_theme_constant_override("outline_size", 9)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)
	var sub := Label.new()
	sub.text = "战棋PVP"
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color(1, 0.85, 0.5))   # 与主标题「酒馆纷争」同色
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)
	vbox.add_child(_spacer(8))

	var add_mode_btn := func(txt: String, cb: Callable) -> void:
		var b := Button.new()
		b.text = txt
		b.add_theme_font_size_override("font_size", 22)
		# 按钮长度：原来 SIZE_EXPAND_FILL 会顶满整行（720 - 左右各 90 = 540），显得太长。
		# 改成固定宽度 + 居中（SHRINK_CENTER），想再长/短就调 MENU_BTN_W 一个数。
		b.custom_minimum_size = Vector2(MENU_BTN_W, 58)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.pressed.connect(cb)
		vbox.add_child(b)
		_attach_hover_dice(b)
	add_mode_btn.call("单机模式", _ask_single_mode)
	add_mode_btn.call("联机模式", _go_net)
	add_mode_btn.call("自由部署（测试）", _go_test_deploy)
	add_mode_btn.call("游戏说明", _open_help)
	add_mode_btn.call("对战统计", _open_stats)
	add_mode_btn.call("复制诊断信息", _copy_diagnostics)
	var quit_btn := Button.new()
	quit_btn.text = "退出游戏"
	quit_btn.add_theme_font_size_override("font_size", 18)
	quit_btn.custom_minimum_size = Vector2(MENU_BTN_W, 46)
	quit_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	quit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(quit_btn)
	_attach_hover_dice(quit_btn)
	_main_msg = Label.new()
	_main_msg.add_theme_font_size_override("font_size", 14)
	_main_msg.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_main_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 长提示自动换行，避免把主菜单列撑宽变形
	_main_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_msg.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(_main_msg)

	# 右下角宣传文字（绝对贴右下，不参与按钮布局）
	var qq := Label.new()
	qq.text = "来Q群：295903423联机打活人"
	qq.add_theme_font_size_override("font_size", 18)
	qq.add_theme_color_override("font_color", Color(1.0, 0.82, 0.4))
	qq.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	qq.add_theme_constant_override("outline_size", 4)
	qq.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	qq.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	qq.offset_left = -430.0
	qq.offset_top = -72.0
	qq.offset_right = -18.0
	qq.offset_bottom = -20.0
	qq.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_main_view.add_child(qq)

# 悬浮骰子：鼠标移到按钮上时，在按钮**前部（左侧）**淡入一颗六点骰子（纯装饰，不接收鼠标）
const HOVER_DICE_PATH := "res://theme/dice_6.png"
const DICE_INSET_X := 14.0   # 骰子距按钮左边缘的像素（= 牌子边框那一圈，不会压到中间的字）
var _dice_tex: Texture2D = null

func _attach_hover_dice(btn: Button) -> void:
	if _dice_tex == null and ResourceLoader.exists(HOVER_DICE_PATH):
		_dice_tex = load(HOVER_DICE_PATH) as Texture2D
	if _dice_tex == null:
		return   # 缺图：整段效果跳过，按钮本身不受影响
	var dice := TextureRect.new()
	dice.texture = _dice_tex
	dice.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dice.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dice.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不能吃掉按钮的悬浮/点击
	dice.modulate.a = 0.0
	dice.visible = false
	btn.add_child(dice)
	var place := func() -> void:
		var d := clampf(btn.size.y - 22.0, 18.0, 36.0)
		dice.size = Vector2(d, d)
		dice.position = Vector2(DICE_INSET_X, (btn.size.y - d) * 0.5)
	btn.resized.connect(place)
	place.call()
	btn.mouse_entered.connect(func():
		dice.visible = true
		var tw := dice.create_tween()
		tw.tween_property(dice, "modulate:a", 1.0, 0.12))
	btn.mouse_exited.connect(func():
		if not is_instance_valid(dice):
			return
		var tw := dice.create_tween()
		tw.tween_property(dice, "modulate:a", 0.0, 0.12)
		tw.tween_callback(func(): dice.visible = false))

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
var _pool_host: Control = null             # 卡池宿主（筛选后整块重建）
var _pool_touch_down := false              # 触屏在卡池区域内按着（拖动池 / 未松手时不跟随 hover 弹框）
const _DETAIL_H := 130.0   # 卡池下方详情预留区高度（随卡池一起滚动可见）

# ---- 英雄池筛选（按钮放在英雄池上方）----
# 【2026-09-23 抽出·用户要求「自由部署的英雄选人界面换成和普通模式一模一样」】
#   筛选的**状态 + 判定 + 弹层 UI** 整段搬进本文件末尾的嵌套类 `HeroFilter`（同 `HUD.VolumeControl`
#   的写法：小功能不另起文件），**普通模式选人页（Menu）与自由部署（QuickTest）共用同一份实现**
#   ⇒ 两边的外观与勾选行为不会再各自漂。这里只留宿主侧的两个控件：按钮 + 计数文案。
var _filter_btn: Button = null
var _filter_info: Label = null            # 按钮右侧"共 N 名 / 筛选后 N / M"提示
var _filter: HeroFilter = null            # 筛选状态机（定义见文件末尾嵌套类）

# 取筛选状态机（首次使用时创建并接好回调：宿主只需"重建卡池 + 刷新计数"两件事）
func _flt() -> HeroFilter:
	if _filter == null:
		_filter = HeroFilter.new()
		_filter.host = self
		_filter.on_changed = func():
			_rebuild_hex_pool()
			_refresh_filter_ui()
		_filter.shown_count = func() -> int:
			return _pool_ids().size()
	return _filter

# 卡池英雄与顺序：按种族分组排（人族→机械→兽族→精灵→魔族），同种族按 hero_id 排——
# 保证初始界面顺序固定，新增英雄无论加在角色列表的哪个位置都落到对应种族区段。
# 有筛选条件时再按条件过滤（只影响显示，不动已选卡组）。
func _pool_ids() -> Array:
	var ids: Array = DataRegistry.heroes.keys()
	ids.sort_custom(func(a: String, b: String):
		var da := DataRegistry.get_hero(a)
		var db := DataRegistry.get_hero(b)
		var ra := da.race if da != null else 99
		var rb := db.race if db != null else 99
		if ra != rb:
			return ra < rb
		return a < b)
	if not _flt().is_active():
		return ids
	var out: Array = []
	for id in ids:
		if _flt().passes(id):
			out.append(id)
	return out

# 重建英雄卡池（筛选条件变化时调用）：只重排卡池，卡组/已选保持不变
func _rebuild_hex_pool() -> void:
	if _pool_host == null or not is_instance_valid(_pool_host):
		return
	_hide_tooltip()
	for c in _pool_host.get_children():
		if c == _detail_label:
			continue   # 详情标签保留，位置随新池高度重排
		_pool_host.remove_child(c)
		c.queue_free()
	_build_hex_pool(_pool_host)
	if _detail_label != null and is_instance_valid(_detail_label):
		_detail_label.position = Vector2(10, _hex_pool_size.y + 6)
	if _pool_scroll != null and is_instance_valid(_pool_scroll):
		_pool_scroll.scroll_vertical = 0   # 筛完回到池顶
	_update_ui()

# 池上方计数 + 筛选按钮文案（弹层内的实时计数由 `HeroFilter.refresh_count()` 自己刷）
func _refresh_filter_ui() -> void:
	var total := DataRegistry.heroes.size()
	var shown := _pool_ids().size()
	if _filter_btn != null and is_instance_valid(_filter_btn):
		_filter_btn.text = _flt().button_text()
	if _filter_info != null and is_instance_valid(_filter_info):
		if not _flt().is_active():
			_filter_info.text = "共 %d 名英雄" % total
		else:
			var hidden_sel := 0
			for id in _selected:
				if not _pool_ids().has(id):
					hidden_sel += 1
			var extra := "（%d 名已选被隐藏，卡组不变）" % hidden_sel if hidden_sel > 0 else ""
			_filter_info.text = "筛选后 %d / %d 名%s" % [shown, total, extra]
	_flt().refresh_count()

# 打开筛选弹层（按钮回调）：先收属性浮层，再交给 `HeroFilter`
func _open_filter() -> void:
	_hide_tooltip()
	_flt().open()

# 英雄卡池：odd-q 蜂窝排布（与棋盘同一套公式：列间距1.5r、奇数列下移半行，
# 六边形边对边贴紧连成蜂窝）。每行 5 张放大卡面，超高时滚动容器出现滚动条。
func _build_hex_pool(host: Control) -> void:
	# 卡池顺序见 _pool_ids()（种族分组 + 筛选条件）。
	var ids: Array = _pool_ids()
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
	# 筛选后一个都不剩：留一块空白区给"无符合条件"提示（别把池压成 0 高）
	if ids.is_empty():
		_hex_pool_size = Vector2(avail_w, 0.0)
		host.custom_minimum_size = Vector2(avail_w, _DETAIL_H)
		host.size = Vector2(avail_w, _DETAIL_H)
		return
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

# 触屏滚动英雄池：模拟器/手机上 ScrollContainer 的原生触摸拖动不总生效，
# 故由本节点 _input 直接接收 ScreenTouch/ScreenDrag 自己滚动（scroll_vertical 赋值自带 0..max 截断）。
# 纵向滚动模式保持 AUTO（Disabled 时 scroll_vertical 赋值无效），桌面滚轮仍由原生处理；
# 按下即抑制 hover 弹框（按住拖动池不弹属性），轻点松开由卡片发 clicked(选人+弹属性)。
func _input(ev: InputEvent) -> void:
	if _pool_scroll == null or not _pool_scroll.is_visible_in_tree() or not _team_view.visible:
		return
	if ev is InputEventScreenTouch:
		var st := ev as InputEventScreenTouch
		if st.pressed:
			_pool_touch_down = _pool_scroll.get_global_rect().has_point(st.position)
			_hide_tooltip()   # 手指按下立即收起（待轻点松开后由点击重新弹出）
		else:
			_pool_touch_down = false
	elif _pool_touch_down and ev is InputEventScreenDrag:
		var sd := ev as InputEventScreenDrag
		# 手指上滑(relative.y<0) -> 内容下滚(数值增大)
		_pool_scroll.scroll_vertical = int(_pool_scroll.scroll_vertical - sd.relative.y)

func _on_hex_hovered(id: String) -> void:
	if _pool_touch_down:
		# 触屏按住（拖动英雄池）期间：不跟随手指位置弹属性框
		_hide_tooltip()
		return
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
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png），这里不再单独覆盖样式
	layer.add_child(_tooltip)
	_tooltip_box = VBoxContainer.new()
	_tooltip_box.add_theme_constant_override("separation", 8)
	# ⚠️ 弹框内层也必须"不接鼠标"：`_tooltip` 自己是 IGNORE，但**子控件照样参与命中**
	#   （VBoxContainer/HSeparator 默认 STOP）⇒ 弹框一旦压住鼠标，下面那张卡就收到 mouse_exited
	#   ⇒ `_hide_tooltip()` ⇒ 弹框消失、鼠标又落回卡上 ⇒ 再弹出……**高频闪烁**。
	_tooltip_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
			sep.custom_minimum_size = Vector2(260, 6)
			sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var lnsb := StyleBoxLine.new()
			lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
			lnsb.thickness = 1
			sep.add_theme_stylebox_override("separator", lnsb)
			sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_tooltip_box.add_child(sep)
		var lb := Label.new()
		lb.text = zones[i]
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.custom_minimum_size = Vector2(380, 0)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tooltip_box.add_child(lb)

func _process(_delta: float) -> void:
	if _tooltip == null or not _tooltip.visible:
		return
	# 弹框跟随鼠标：**优先放鼠标右下**，越界就整块翻到另一侧（左侧/上方）。
	# ⚠️ 别退回"只夹到屏幕内"：卡组小卡在屏幕底部，弹框被下边界夹回去时会**压住鼠标**
	#   —— 即便内层不接鼠标（见 `_build_tooltip`），弹框盖住正在看的那张卡本身也难看。
	var vs := get_viewport().get_visible_rect().size
	var m := get_viewport().get_mouse_position()
	var sz := _tooltip.size
	var x := m.x + 14.0
	if x + sz.x > vs.x - 8.0:
		x = m.x - sz.x - 14.0
	var y := m.y + 14.0
	if y + sz.y > vs.y - 8.0:
		y = m.y - sz.y - 14.0
	_tooltip.position = Vector2(
			clampf(x, 8.0, maxf(vs.x - sz.x - 8.0, 8.0)),
			clampf(y, 8.0, maxf(vs.y - sz.y - 8.0, 8.0)))

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

# 点"自备卡组"里的小卡 = 把该英雄从当前卡组去掉（等价于回英雄池再点它一次取消选择）。
# ⚠️ 不要直接复用 `_on_hex_clicked`：它末尾要写 `_card_buttons[id]`，而英雄池**被筛选时**
#   该 id 可能根本不在池子里（没有对应卡）⇒ 会抛 Invalid index/key。
func _on_deck_card_clicked(id: String) -> void:
	if not _selected.has(id):
		return
	_selected.erase(id)
	var pool_card: Variant = _card_buttons.get(id)
	if pool_card != null and is_instance_valid(pool_card):
		pool_card.set_selected(false)   # 池子里那张同步取消高亮（被筛掉时就没有它，跳过）
	_hide_tooltip()      # 这张小卡马上要被重建掉、不会再发 mouse_exited ⇒ 属性框先收起，反馈更干净
	_update_ui()         # 计数 + 自动保存 + 重建卡组预览（这一张随之消失）

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
	_start_btn.disabled = false   # 入场前不再校验队伍：开战后在场内选卡组（不足 5 名时由场内提示）
	for id in _card_buttons.keys():
		_card_buttons[id].set_selected(_selected.has(id))
	if _sel_count != null:
		_sel_count.text = "已选 %d / %d" % [_selected.size(), PICK_COUNT]
	_refresh_filter_ui()   # 池上方计数（含"已选但被筛掉"的提示）
	_auto_sync()
	_refresh_deck_slots()

# 阵容任一变化 → 自动写回当前卡组槽（内容相同则不重复写盘）。
# 仅在普通模式页可见(用户进入选人/编辑)时生效：
# 页面构建阶段(尚未显示)当前阵容为空，若盲目同步会把槽位存档覆盖成空。
func _auto_sync() -> void:
	if _team_view == null or not _team_view.visible:
		return
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
	# 新流程：入场前不再锁定队伍——进入战斗后弹"选择卡组"面板（三选一已存卡组 / 随机英雄）。
	# 编辑页仍可编辑英雄（改动自动保存到卡组槽），场内只选已保存的卡组。
	GameState.pick_deck_in_battle = true
	GameState.clear_placement()   # 普通模式用正常部署，不沿用"自由部署"放置，避免选人异常
	GameState.no_death_limit = false   # 正式模式用 3 人判负规则
	GameState.dual_control = false
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
		card.clicked.connect(_on_deck_card_clicked)   # 点小卡 = 从卡组里去掉这个英雄
		_deck_host.add_child(card)

func _go_test_deploy() -> void:
	get_tree().change_scene_to_file("res://scenes/QuickTest.tscn")

# ---- 单机模式入口：把「普通模式 / 竞技场模式」合并成一个按钮，点开再选玩法 ----
# 两个玩法各自的流程一个字没改，只是入口从"主菜单两个平级按钮"变成"一个按钮 + 弹出选择"：
#   普通模式 → 原来的 _show_team_view()（编队页）；竞技场模式 → 原来的 _go_arena()（接着弹"选择 AI 难度"）。
var _single_mode_overlay: Control = null

func _ask_single_mode() -> void:
	if _single_mode_overlay != null and is_instance_valid(_single_mode_overlay):
		return
	var vsize := get_viewport().get_visible_rect().size
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	_single_mode_overlay = ov
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(dim)
	# 居中交给 CenterContainer：面板尺寸由内容决定，容器自己算位置。
	# 不再手算 (vsize - panel.size)/2 —— 那个写法依赖 reset_size() 之后的尺寸，内容一多就会顶偏/顶出屏幕。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(center)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.custom_minimum_size = Vector2(minf(430.0, vsize.x * 0.78), 0.0)   # 窄屏也不会超出屏幕
	panel.add_child(box)
	# 【2026-09-23 用户要求】标题行改成"标题 + 右上角问号"：原来每个玩法下面那一行小字介绍**已删**
	#   （用户原话：「把单机模式弹框里面的介绍删掉，右上角加一个问号，点开弹游戏模式说明」）。
	#   用一层 Control 当标题行：标题铺满居中、问号用锚点钉在这一行的右上角，
	#   这样标题仍然**真正居中**（不会被按钮挤偏），也不依赖"面板尺寸算完才知道坐标"。
	var head := Control.new()
	head.custom_minimum_size = Vector2(0, 36)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 自己不吃鼠标；子节点（问号按钮）照常可点
	box.add_child(head)
	var title := Label.new()
	title.text = "单机模式 · 选择玩法"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_FULL_RECT)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(title)
	# 右上角的"?"：点开「游戏模式说明」弹窗
	var help_btn := Button.new()
	help_btn.text = "?"
	help_btn.tooltip_text = "游戏模式说明"
	help_btn.add_theme_font_size_override("font_size", 16)
	help_btn.focus_mode = Control.FOCUS_NONE
	help_btn.anchor_left = 1.0
	help_btn.anchor_right = 1.0
	help_btn.anchor_top = 0.0
	help_btn.anchor_bottom = 0.0
	help_btn.offset_left = -36.0
	help_btn.offset_right = 0.0
	help_btn.offset_top = 0.0
	help_btn.offset_bottom = 32.0
	help_btn.pressed.connect(_open_mode_help)
	head.add_child(help_btn)
	# 每个玩法一个大按钮（介绍文字已删，玩法差异改由右上角「?」里的说明承担）
	var add := func(txt: String, cb: Callable) -> void:
		var b := Button.new()
		b.text = txt
		b.custom_minimum_size = Vector2(0, 56)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(cb)
		box.add_child(b)
	add.call("普通模式", _single_mode_normal)
	add.call("竞技场模式", _single_mode_arena)
	var cancel := Button.new()
	cancel.text = "返回"
	cancel.custom_minimum_size = Vector2(0, 48)
	cancel.add_theme_font_size_override("font_size", 18)
	cancel.pressed.connect(_close_single_mode)
	box.add_child(cancel)

func _close_single_mode() -> void:
	if _single_mode_overlay != null and is_instance_valid(_single_mode_overlay):
		_single_mode_overlay.queue_free()
	_single_mode_overlay = null

func _single_mode_normal() -> void:
	_close_single_mode()
	_show_team_view()

func _single_mode_arena() -> void:
	_close_single_mode()
	_go_arena()   # 竞技场：紧接着弹「选择 AI 难度」

# ---- 【2026-09-23 用户要求】「单机模式 · 选择玩法」弹框右上角那个"?"的说明窗 ----
# 为什么单独写一份文本、而不直接复用主菜单的 `RULES_TEXT`：用户要的是**游戏模式说明**
#   （普通模式 / 竞技场模式各自怎么开局、差在哪），而 `RULES_TEXT` 是全套玩法与关键词。
#   末尾留一句指路：要看完整规则就去主菜单「游戏说明」。
const MODE_HELP_TEXT := "《酒馆纷争》游戏模式说明\n\n【普通模式】\n· 进对局前先在编队页组队：从英雄池里选5-8名英雄，\n· 开战后在战斗内弹出「选择卡组」：从 3 个已存卡组里挑一个出战，也可以点「随机英雄」直接随机。\n\n【竞技场模式】\n· 开局进入选人界面：双方各选4次 ；没被选择的英雄进入对方卡组\n· 双方各凑 8 名之后轮流上首发，其余进替补席。\n\n【两种模式共同的规则】\n· 每队 3 名首发上场，其余替补待命；一方累计阵亡 3 名英雄（含替补）即判负。\n·更完整的玩法与关键词说明，见主菜单的「游戏说明」。"

var _mode_help_overlay: Control = null

func _open_mode_help() -> void:
	if _mode_help_overlay != null and is_instance_valid(_mode_help_overlay):
		return
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)      # 加在「单机模式」弹层之后 ⇒ 盖在它上面；关掉后单机弹框还在
	_mode_help_overlay = overlay
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	center.add_child(panel)
	var pw := minf(vsize.x - 48.0, 640.0)
	var ph := minf(vsize.y - 120.0, 780.0)
	panel.custom_minimum_size = Vector2(pw, ph)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "游戏模式说明"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)
	var body := Label.new()
	body.text = MODE_HELP_TEXT
	body.add_theme_font_size_override("font_size", 15)
	body.add_theme_color_override("font_color", Color(0.92, 0.93, 1.0))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(pw - 60.0, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 44)
	close.pressed.connect(_close_mode_help)
	vb.add_child(close)

func _close_mode_help() -> void:
	if _mode_help_overlay != null and is_instance_valid(_mode_help_overlay):
		_mode_help_overlay.queue_free()
	_mode_help_overlay = null

# 竞技场模式：先选 AI 难度，再进入对局（随机2选1构建双方卡组）
func _go_arena() -> void:
	_ask_arena_difficulty()

var _arena_dif_overlay: Control = null   # 竞技场难度选择弹层

func _ask_arena_difficulty() -> void:
	if _arena_dif_overlay != null and is_instance_valid(_arena_dif_overlay):
		return
	var vsize := get_viewport().get_visible_rect().size
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(ov)
	_arena_dif_overlay = ov
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(dim)
	# 居中交给 CenterContainer（同「单机模式」弹窗）：不手算坐标，面板多大都居中、不会顶出屏幕。
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(center)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(minf(430.0, vsize.x * 0.78), 0.0)
	panel.add_child(box)
	var title := Label.new()
	title.text = "竞技场模式 · 选择 AI 难度"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var add := func(txt: String, val: int) -> void:
		var b := Button.new()
		b.text = txt
		b.custom_minimum_size = Vector2(0, 60)
		b.add_theme_font_size_override("font_size", 22)
		b.pressed.connect(_start_arena.bind(val))
		box.add_child(b)
	add.call("简单", 0)
	add.call("普通", 1)
	add.call("困难", 2)
	add.call("噩梦", 3)    # 第 4 档（最后一档）：RL 候选 AI + 训练权重（英雄特化段同文件，同上）
	var cancel := Button.new()
	cancel.text = "返回"
	cancel.custom_minimum_size = Vector2(0, 48)
	cancel.add_theme_font_size_override("font_size", 18)
	cancel.pressed.connect(func():
		if _arena_dif_overlay != null:
			_arena_dif_overlay.queue_free()
			_arena_dif_overlay = null)
	box.add_child(cancel)

func _start_arena(dif: int) -> void:
	if _arena_dif_overlay != null:
		_arena_dif_overlay.queue_free()
		_arena_dif_overlay = null
	GameState.ai_difficulty = dif
	GameState.arena_mode = true
	GameState.no_death_limit = false   # 正式模式用 3 人判负规则
	GameState.dual_control = false
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
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
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

# ---- 对战统计弹窗：四种模式的胜场/败场/胜率 + 重置 ----
func _open_stats() -> void:
	if _stats_overlay != null and is_instance_valid(_stats_overlay):
		_stats_overlay.queue_free()
		_stats_overlay = null
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_stats_overlay = overlay
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "对战统计"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	# 表头 + 四行数据（模式 / 胜场 / 败场 / 胜率）
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(grid)
	var col_w := [220.0, 76.0, 76.0, 96.0]
	for i in 4:
		var head := Label.new()
		head.text = ["模式", "胜场", "败场", "胜率"][i]
		head.add_theme_font_size_override("font_size", 15)
		head.add_theme_color_override("font_color", Color(0.75, 0.8, 0.92))
		head.custom_minimum_size = Vector2(col_w[i], 0)
		head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if i > 0 else HORIZONTAL_ALIGNMENT_LEFT
		grid.add_child(head)
	for key in Stats.MODES:
		var name_lb := Label.new()
		name_lb.text = Stats.mode_name(key)
		name_lb.add_theme_font_size_override("font_size", 17)
		name_lb.add_theme_color_override("font_color", Color(0.92, 0.93, 1.0))
		name_lb.custom_minimum_size = Vector2(col_w[0], 0)
		grid.add_child(name_lb)
		var w_lb := Label.new()
		w_lb.text = str(Stats.win_count(key))
		w_lb.add_theme_font_size_override("font_size", 17)
		w_lb.add_theme_color_override("font_color", Color(0.55, 0.95, 0.6))
		w_lb.custom_minimum_size = Vector2(col_w[1], 0)
		w_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		grid.add_child(w_lb)
		var l_lb := Label.new()
		l_lb.text = str(Stats.loss_count(key))
		l_lb.add_theme_font_size_override("font_size", 17)
		l_lb.add_theme_color_override("font_color", Color(1.0, 0.55, 0.55))
		l_lb.custom_minimum_size = Vector2(col_w[2], 0)
		l_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		grid.add_child(l_lb)
		var r_lb := Label.new()
		r_lb.text = Stats.win_rate_text(key)
		r_lb.add_theme_font_size_override("font_size", 17)
		r_lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
		r_lb.custom_minimum_size = Vector2(col_w[3], 0)
		r_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		grid.add_child(r_lb)
	# 总计
	var total_w := 0
	var total_l := 0
	for key in Stats.MODES:
		total_w += Stats.win_count(key)
		total_l += Stats.loss_count(key)
	var total_lb := Label.new()
	var total_txt := "总计：胜 %d · 败 %d" % [total_w, total_l]
	if total_w + total_l > 0:
		total_txt += " · 胜率 %.1f%%" % (float(total_w) / float(total_w + total_l) * 100.0)
	total_lb.text = total_txt
	total_lb.add_theme_font_size_override("font_size", 16)
	total_lb.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	total_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(total_lb)
	var hint := Label.new()
	hint.text = "只统计双方以「一方累计 3 名英雄阵亡」分出胜负的对局；中途退出、断线不算。"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(minf(vsize.x - 90.0, 500.0), 0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	# 按钮：重置统计 / 关闭
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vb.add_child(btn_row)
	var reset := Button.new()
	reset.text = "重置统计"
	reset.add_theme_font_size_override("font_size", 17)
	reset.custom_minimum_size = Vector2(0, 44)
	reset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset.pressed.connect(_confirm_reset_stats)
	btn_row.add_child(reset)
	var close := Button.new()
	close.text = "关闭"
	close.add_theme_font_size_override("font_size", 17)
	close.custom_minimum_size = Vector2(0, 44)
	close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close.pressed.connect(_close_stats)
	btn_row.add_child(close)
	# 尺寸与居中
	panel.reset_size()
	var min_sz := panel.get_combined_minimum_size()
	var pw: float = clampf(maxf(min_sz.x, 420.0), 420.0, maxf(vsize.x - 40.0, 420.0))
	var ph: float = minf(min_sz.y, vsize.y - 40.0)
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	panel.position = Vector2((vsize.x - pw) / 2.0, maxf((vsize.y - ph) / 2.0, 20.0))

# 重置统计：二次确认后清零并刷新面板
func _confirm_reset_stats() -> void:
	var d := ConfirmationDialog.new()
	d.title = "重置统计"
	d.dialog_text = "确定要把所有模式的对战统计清零吗？此操作不可撤销。"
	d.ok_button_text = "确定重置"
	d.cancel_button_text = "取消"
	d.confirmed.connect(_do_reset_stats)
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	add_child(d)
	d.popup_centered()

func _do_reset_stats() -> void:
	Stats.reset_all()
	_open_stats()   # 重建面板刷新显示

func _close_stats() -> void:
	if _stats_overlay != null and is_instance_valid(_stats_overlay):
		_stats_overlay.queue_free()
	_stats_overlay = null

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

# 【2026-09-23 抽出·用户要求「自由部署的英雄选人界面换成和普通模式一模一样」】
#   英雄池**筛选**：状态 + 判定 + 弹层 UI。原来整段写在 `Menu` 里，现在抽成嵌套类给两个界面共用
#   （普通模式选人页 = `Menu`；自由部署 = `QuickTest`）⇒ 两边的按钮文案、弹层、勾选规则、配色完全一致，
#   以后也不会各自漂。**小功能不另起文件**：同 `HUD.VolumeControl` / `HUD.DeathMark` 的写法。
#
#   宿主侧只要接四件事：
#     var flt := Menu.HeroFilter.new()
#     flt.host = self                                      # 弹层挂到谁身上（一般就是宿主自己）
#     flt.on_changed = func(): 重建卡池; 刷新计数           # 勾选/重置后回调
#     flt.shown_count = func() -> int: return 符合条件人数  # 弹层里"符合条件：N 名"的实时读数
#   之后：`flt.passes(id)` 过滤卡池、`flt.button_text()` 当按钮文案、
#         `flt.open()` 开弹层、`flt.refresh_count()` 刷弹层内计数、`flt.is_active()` 判断有无条件。
#
#   四组条件（与原实现逐字一致）：①特性关键词 ②血量档 ③攻击力档 ④攻击方式（近战/远程）。
#   组内多选=或（满足任一即可），组间=且；某组一个都不选 = 该组不参与筛选。
#   ⚠️ 特性组例外：多选要求**全部满足**；"无特性"= 一个关键词都没有，与其它特性互斥（界面层保证不同时选中）。
class HeroFilter extends RefCounted:
	const TAGS := ["嘲讽", "疾行", "渗透", "后勤", "替补", "无特性"]
	const HP_BUCKETS := ["≤15", "16-20", "21-25", "≥26"]
	const ATK_BUCKETS := ["≤1", "2", "3", "≥4"]
	const KINDS := ["近战", "远程"]

	var tags: Array = []          # 选中的特性（字符串）
	var hps: Array = []           # 选中的血量档（下标 0..3）
	var atks: Array = []          # 选中的攻击力档（下标 0..3）
	var kinds: Array = []         # 选中的攻击方式（0=近战 1=远程）
	var host: Control = null      # 弹层挂到哪个节点
	var on_changed: Callable = Callable()    # 勾选/重置后回调（宿主重建卡池 + 刷新计数）
	var shown_count: Callable = Callable()   # 返回"符合条件的人数"（弹层内实时计数）

	var _overlay: Control = null
	var _chips: Array = []
	var _count_lb: Label = null
	var _on_sb: StyleBoxFlat = null
	var _focus_sb: StyleBoxFlat = null

	func is_active() -> bool:
		return count_active() > 0

	func count_active() -> int:
		return tags.size() + hps.size() + atks.size() + kinds.size()

	# 池上方那颗按钮的文案（0 项 = "筛选"，N 项 = "筛选（N 项）"）
	func button_text() -> String:
		var n := count_active()
		return "筛选" if n == 0 else "筛选（%d 项）" % n

	# 组内多选=或（命中任一即可），组间=且；特性组要求全部满足
	func passes(id: String) -> bool:
		var def: DataRegistry.HeroDef = DataRegistry.get_hero(id)
		if def == null:
			return false
		if kinds.size() > 0:
			var kind := 1 if def.attack_type == DataRegistry.AttackType.RANGED else 0
			if not kinds.has(kind):
				return false
		if hps.size() > 0 and not hps.has(_hp_bucket(def)):
			return false
		if atks.size() > 0 and not atks.has(_atk_bucket(def)):
			return false
		if tags.size() > 0:
			var ht := _hero_tags(def)
			for t in tags:
				if t == "无特性":
					if not ht.is_empty():
						return false
				elif not ht.has(t):
					return false
		return true

	# 弹层里"符合条件：N 名英雄"（宿主给了 shown_count 才算；没给就只显示已勾选数）
	func refresh_count() -> void:
		if _count_lb == null or not is_instance_valid(_count_lb):
			return
		var n := 0
		if shown_count.is_valid():
			n = int(shown_count.call())
		_count_lb.text = "符合条件：%d 名英雄" % n

	func reset() -> void:
		tags.clear()
		hps.clear()
		atks.clear()
		kinds.clear()
		for b in _chips:
			if b != null and is_instance_valid(b):
				b.set_pressed_no_signal(false)   # 不触发信号：状态已清空，最后统一刷新
				_paint_chip(b)
		_changed()

	func close() -> void:
		if _overlay != null and is_instance_valid(_overlay):
			_overlay.queue_free()
		_overlay = null
		_count_lb = null
		_chips.clear()

	# ---- 弹层 ----
	func open() -> void:
		if _overlay != null and is_instance_valid(_overlay):
			return
		if host == null or not is_instance_valid(host):
			return
		var vsize: Vector2 = host.get_viewport().get_visible_rect().size
		var ov := Control.new()
		ov.set_anchors_preset(Control.PRESET_FULL_RECT)
		ov.mouse_filter = Control.MOUSE_FILTER_STOP
		# 选中的英雄卡会把自身 z_index 提到 2（避免高亮描边被邻卡盖住）；z 排序优先于添加顺序，
		# 所以弹层要显式抬到它之上，否则已选英雄会画在筛选框上面。
		ov.z_index = 20
		# 点弹框外面（遮罩那块空白）也关掉：遮罩/居中容器都设成"不接鼠标"，
		# 只有面板本体吃点击，于是落在空白处的点击会冒泡到 ov 自己身上。
		ov.gui_input.connect(_on_overlay_input)
		host.add_child(ov)
		_overlay = ov
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.6)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov.add_child(dim)
		var center := CenterContainer.new()
		center.set_anchors_preset(Control.PRESET_FULL_RECT)
		center.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ov.add_child(center)
		var panel := PanelContainer.new()
		# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
		center.add_child(panel)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 10)
		box.custom_minimum_size = Vector2(minf(520.0, vsize.x * 0.9), 0.0)   # 窄屏也不会超出屏幕
		panel.add_child(box)
		var title := Label.new()
		title.text = "筛选英雄"
		title.add_theme_font_size_override("font_size", 26)
		title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(title)
		_chips.clear()
		_add_group(box, "特性", "tag", TAGS)
		_add_group(box, "血量（HP）", "hp", HP_BUCKETS)
		_add_group(box, "攻击力", "atk", ATK_BUCKETS)
		_add_group(box, "攻击方式", "kind", KINDS)
		_count_lb = Label.new()
		_count_lb.add_theme_font_size_override("font_size", 15)
		_count_lb.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
		_count_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(_count_lb)
		var hint := Label.new()
		hint.text = "特性：勾中的几项要同时满足；血量 / 攻击力：勾中的项满足其一即可；攻击方式：只能选一个。不同组之间要同时满足。勾选即生效。"
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.72, 0.78, 0.88))
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(hint)
		var btn_row := HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 10)
		box.add_child(btn_row)
		var rst := Button.new()
		rst.text = "重置"
		rst.custom_minimum_size = Vector2(0, 46)
		rst.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rst.add_theme_font_size_override("font_size", 18)
		rst.pressed.connect(reset)
		btn_row.add_child(rst)
		var cls := Button.new()
		cls.text = "关闭"
		cls.custom_minimum_size = Vector2(0, 46)
		cls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cls.add_theme_font_size_override("font_size", 18)
		cls.pressed.connect(close)
		btn_row.add_child(cls)
		refresh_count()

	# ---- 内部 ----
	func _changed() -> void:
		if on_changed.is_valid():
			on_changed.call()
		refresh_count()

	func _group_array(group_key: String) -> Array:
		match group_key:
			"tag":
				return tags
			"hp":
				return hps
			"atk":
				return atks
		return kinds

	# 英雄自带的关键词特性（卡面 <xxx>）。远程归"攻击方式"组，这里不含。
	func _hero_tags(def: DataRegistry.HeroDef) -> Array:
		var out: Array = []
		if def == null:
			return out
		if def.skills.has(DataRegistry.Skill.TAUNT):
			out.append("嘲讽")
		if def.skills.has(DataRegistry.Skill.SWIFT):
			out.append("疾行")
		if def.skills.has(DataRegistry.Skill.INFILTRATE):
			out.append("渗透")
		if def.skills.has(DataRegistry.Skill.LOGISTICS):
			out.append("后勤")
		if def.skills.has(DataRegistry.Skill.BENCH):
			out.append("替补")
		return out

	# 血量档：0=≤15、1=16-20、2=21-25、3=≥26
	func _hp_bucket(def: DataRegistry.HeroDef) -> int:
		if def.max_hp <= 15:
			return 0
		if def.max_hp <= 20:
			return 1
		if def.max_hp <= 25:
			return 2
		return 3

	# 攻击力档：0=≤1、1=2、2=3、3=≥4
	func _atk_bucket(def: DataRegistry.HeroDef) -> int:
		if def.atk <= 1:
			return 0
		if def.atk == 2:
			return 1
		if def.atk == 3:
			return 2
		return 3

	# 取消同组其它方块的勾选（单选组 / 互斥项用；不触发信号，状态由调用方直接写）
	func _untoggle_group_except(group_key: String, keep: Button) -> void:
		for b in _chips:
			if b == null or not is_instance_valid(b) or b == keep:
				continue
			if String(b.get_meta("group")) != group_key:
				continue
			if b.button_pressed:
				b.set_pressed_no_signal(false)
				_paint_chip(b)

	func _on_chip(btn: Button) -> void:
		if btn == null or not is_instance_valid(btn):
			return
		var group := String(btn.get_meta("group"))
		var arr: Array = _group_array(group)
		var v: Variant = btn.get_meta("value")
		if btn.button_pressed:
			if group == "kind":
				# 攻击方式：单选 —— 勾一个就把另一个取消
				arr.clear()
				arr.append(v)
				_untoggle_group_except("kind", btn)
			elif group == "tag" and String(v) == "无特性":
				# "无特性"与其它特性互斥：勾它就把别的特性取消
				arr.clear()
				arr.append(v)
				_untoggle_group_except("tag", btn)
			elif not arr.has(v):
				arr.append(v)
		else:
			arr.erase(v)
		_paint_chip(btn)
		_changed()

	# 选中的方块：绿色高亮边框（与选人卡面选中描边同色）+ 深绿底 + 亮字，一眼看出勾了哪些。
	# 未选中则撤掉覆盖样式，回到主题那款黑色金属牌。
	func _chip_on_stylebox() -> StyleBoxFlat:
		if _on_sb == null:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.09, 0.27, 0.15, 0.96)
			sb.set_border_width_all(3)
			sb.border_color = Color(0.30, 1.0, 0.45)
			sb.set_corner_radius_all(10)
			sb.content_margin_left = 14.0
			sb.content_margin_right = 14.0
			sb.content_margin_top = 6.0
			sb.content_margin_bottom = 7.0
			_on_sb = sb
		return _on_sb

	# 焦点框：只描边不填底（否则键盘焦点会把字盖住），同样用绿色
	func _chip_focus_stylebox() -> StyleBoxFlat:
		if _focus_sb == null:
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0, 0, 0, 0)
			sb.set_border_width_all(2)
			sb.border_color = Color(0.55, 1.0, 0.65, 0.95)
			sb.set_corner_radius_all(10)
			_focus_sb = sb
		return _focus_sb

	func _paint_chip(btn: Button) -> void:
		if btn.button_pressed:
			var sb := _chip_on_stylebox()
			btn.add_theme_stylebox_override("normal", sb)
			btn.add_theme_stylebox_override("hover", sb)
			btn.add_theme_stylebox_override("pressed", sb)
			btn.add_theme_stylebox_override("hover_pressed", sb)
			btn.add_theme_stylebox_override("focus", _chip_focus_stylebox())
			btn.add_theme_color_override("font_color", Color(0.92, 1.0, 0.9))
			btn.add_theme_color_override("font_hover_color", Color(1, 1, 1))
			btn.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
		else:
			for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
				btn.remove_theme_stylebox_override(st)
			btn.add_theme_color_override("font_color", Color(0.93, 0.94, 1.0))
			btn.add_theme_color_override("font_hover_color", Color(1.0, 0.93, 0.7))
			btn.remove_theme_color_override("font_pressed_color")

	# 一行筛选组：标题 + 可多选的方块按钮（自动换行）
	func _add_group(parent: Control, title: String, group_key: String, labels: Array) -> void:
		var sel: Array = _group_array(group_key)
		var head := Label.new()
		head.text = title
		head.add_theme_font_size_override("font_size", 16)
		head.add_theme_color_override("font_color", Color(0.8, 0.86, 0.98))
		parent.add_child(head)
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		flow.add_theme_constant_override("v_separation", 8)
		flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parent.add_child(flow)
		for i in labels.size():
			# 特性组用名字当值，其余组用档位下标
			var value: Variant = labels[i] if group_key == "tag" else i
			var b := Button.new()
			b.text = String(labels[i])
			b.toggle_mode = true
			b.button_pressed = sel.has(value)
			b.custom_minimum_size = Vector2(0, 42)
			b.add_theme_font_size_override("font_size", 16)
			b.set_meta("group", group_key)
			b.set_meta("value", value)
			_paint_chip(b)
			b.toggled.connect(func(_on: bool): _on_chip(b))
			flow.add_child(b)
			_chips.append(b)

	# 点弹框外面的遮罩区域也关掉弹框（落在面板上的点击由面板吃掉，不会走到这里）
	func _on_overlay_input(ev: InputEvent) -> void:
		var hit := false
		if ev is InputEventMouseButton:
			var mb := ev as InputEventMouseButton
			hit = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
		elif ev is InputEventScreenTouch:
			hit = (ev as InputEventScreenTouch).pressed
		if hit:
			host.get_viewport().set_input_as_handled()   # 这一下只用来关弹框，不再传给底下的界面
			close()
