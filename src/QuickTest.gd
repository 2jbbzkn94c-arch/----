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
var _status_label: Label
var _side_btns: Array = []   # 【2026-09-23】「编辑我方/编辑敌方」两个按钮（高亮表示当前编辑哪一方）
var _start_btn: Button
var _pool_scroll: ScrollContainer = null   # 英雄池滚动容器（触屏拖动）
var _pool_host: Control = null             # 英雄池宿主（筛选后整块重建）
var _filter_btn: Button = null             # 筛选按钮（与普通模式同款）
var _filter_info: Label = null             # 筛选按钮右侧"共 N 名 / 筛选后 N / M"提示
var _filter: Menu.HeroFilter = null        # 筛选状态机 = 普通模式那份实现（Menu 的嵌套类）
var _pool_touch_down := false              # 触屏按住英雄池中
var _squad_cap: Label = null               # 英雄池下方"已选队伍"标题行
var _squad_clear_btn: Button = null        # 标题行右端「清空」按钮（用户要求：清空放进队伍列表里）
var _squad_host: Control = null            # "已选队伍"小卡宿主（每次刷新整块重建）
var _enemy_ai := false                     # 敌方是否交给 AI（不勾选=双控，双方都归玩家）
var _diff_opt: OptionButton = null          # AI 难度下拉（敌方为 AI 时生效）
const AI_DIFF_NAMES := ["简单", "普通", "困难", "噩梦"]   # 与 Menu 的四档一致（2026-09-20 删除第 5 档「噩梦+」）

# 测试场里各队可上场的格子（底部行我方 / 第一满行敌方），只放首发 3 个
const PLAYER_CELLS := [Vector2i(0, 6), Vector2i(2, 6), Vector2i(4, 6)]
const ENEMY_CELLS := [Vector2i(0, 1), Vector2i(2, 1), Vector2i(4, 1)]

# ---- 队伍存档（我方 / 敌方各 1 组，分开存；改动即自动保存、进页自动载入）----
# 【2026-09-23 用户要求】自由部署也加队伍保存：我方、敌方**分开**存，每侧只留 1 组
#   （不像普通模式那样 3 个卡组槽）。手感与普通模式卡组一致：**改动立刻写盘**，
#   再进本页 / 重启游戏都会自动恢复上次的两支队伍。
# 存档写在自己的 cfg 里，**不碰 `DeckStore` 的 3 个卡组槽** —— 那 3 个槽会被战斗内
#   "选择卡组"面板逐个列出来，沙箱队伍混进去会污染正常对局的选卡组界面。
const TEAM_SAVE_PATH := "user://quicktest_teams.cfg"

func _ready() -> void:
	# 【2026-09-28·用户要求】菜单页背景音乐（原版 BGM_Main）
	AudioManager.play_music("menu")
	_build()

## 【2026-09-28·用户要求】点英雄池英雄：先响原版 `Click_SelectActor`，再走原来的选/取消逻辑
func _on_pool_card_clicked(hid: String) -> void:
	AudioManager.play("select_actor")
	_toggle(hid)
	_build_tooltip()   # 英雄属性框（悬停/点选英雄卡时弹出）
	set_process_input(true)   # 触屏拖动英雄池

# ---- 英雄属性框：与普通模式选人页同一套格式（DataRegistry.hero_info_zones）----
# 之前这一页只有"点卡=选人"，没有悬停/点选弹属性，所以在自由部署页看不到英雄属性框。
var _tooltip: PanelContainer = null
var _tooltip_box: VBoxContainer = null

func _build_tooltip() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	layer.add_child(_tooltip)
	_tooltip_box = VBoxContainer.new()
	# 【2026-09-21 修·右下角属性框闪烁】内层容器/标签**必须**也 IGNORE：
	#   `mouse_filter` 是**逐控件**判定的 —— 外层设 IGNORE 只代表"外层自己不接收"，
	#   子控件默认是 STOP，照样会被鼠标命中。属性框一旦吃了鼠标，被它盖住的那张英雄卡
	#   就会收到 `mouse_exited`（见 `HexCard` 的 hovered 信号）⇒ 属性框隐藏 ⇒ 鼠标又落回卡片
	#   ⇒ `mouse_entered` ⇒ 再弹出 …… 每帧一次 = 一闪一闪。右下角必现，因为那里的
	#   边界夹取会把属性框**正好推到鼠标底下**（见 `_process` 里的定位）。
	_tooltip_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_box.add_theme_constant_override("separation", 8)
	_tooltip.add_child(_tooltip_box)

# 属性表按"显示区"分行：名字/基础属性/技能描述/词条解释，区之间插一条贴左短线。
func _set_tooltip_zones(zones: Array) -> void:
	for c in _tooltip_box.get_children():
		_tooltip_box.remove_child(c)
		c.queue_free()
	for i in zones.size():
		if i > 0:
			var sep := HSeparator.new()
			sep.custom_minimum_size = Vector2(260, 6)
			sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var lnsb := StyleBoxLine.new()
			lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
			lnsb.thickness = 1
			sep.add_theme_stylebox_override("separator", lnsb)
			sep.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 属性框整层不接收鼠标（见 _build_tooltip 的说明）
			_tooltip_box.add_child(sep)
		var lb := Label.new()
		lb.text = zones[i]
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.custom_minimum_size = Vector2(380, 0)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE       # 同上：标签默认 STOP 会吃掉鼠标 ⇒ 闪烁
		_tooltip_box.add_child(lb)

func _show_detail(id: String) -> void:
	if _tooltip_box == null:
		return
	var def: DataRegistry.HeroDef = DataRegistry.get_hero(id)
	if def == null:
		return
	_set_tooltip_zones(DataRegistry.hero_info_zones(def))
	# 面板直接挂在 CanvasLayer 下、无容器重排：内容变化后重置到新内容的最小尺寸，
	# 否则先看长描述英雄会被撑高，之后看短描述的底部残留留白。
	_tooltip.reset_size()
	_tooltip.visible = true

func _hide_tooltip() -> void:
	if _tooltip != null:
		_tooltip.visible = false

func _on_hex_hovered(id: String) -> void:
	if _pool_touch_down:
		_hide_tooltip()   # 触屏按住拖动英雄池：不弹属性框
		return
	if id == "":
		_hide_tooltip()
	else:
		_show_detail(id)

# 属性框跟随鼠标（默认贴右下 14px；右边/下边放不下时**翻到另一侧**，再收敛到屏内）
# 【2026-09-21 修·右下角闪烁】原来是"贴右下 + 越界就 minf 硬夹回屏内"：在右下角两处夹取同时生效，
#   属性框会被推到**正好压在鼠标底下**，于是鼠标落进属性框 ⇒ 卡片 `mouse_exited` ⇒ 隐藏 ⇒
#   鼠标又回到卡片 ⇒ `mouse_entered` ⇒ 再弹出 —— 每帧一次。改成"HUD 属性浮层"那套做法：
#   先翻到鼠标左上，再夹进屏内（夹取带 8px 边距），正常情况下框的右下缘离指针 14px ⇒ 不会压住指针。
func _process(_delta: float) -> void:
	if _tooltip != null and _tooltip.visible:
		var vs := get_viewport().get_visible_rect().size
		var mp := get_viewport().get_mouse_position()
		var tw := _tooltip.size.x
		var th := _tooltip.size.y
		var pos := mp + Vector2(14, 14)
		if pos.x + tw > vs.x - 8.0:
			pos.x = mp.x - tw - 14.0     # 右边放不下 ⇒ 翻到鼠标左侧
		if pos.y + th > vs.y - 8.0:
			pos.y = mp.y - th - 14.0     # 下边放不下 ⇒ 翻到鼠标上方
		pos.x = clampf(pos.x, 8.0, maxf(8.0, vs.x - tw - 8.0))
		pos.y = clampf(pos.y, 8.0, maxf(8.0, vs.y - th - 8.0))
		_tooltip.position = pos

func _cur() -> Array:
	return _sel_p if _side == 0 else _sel_e

# 界面背景贴图（**与主菜单同一张、同一取景**）：用户 2026-09-28 报「自由部署界面的背景图没了」——
#   原因：这里原来只挂 `assets/美术资源/背景/界面背景_六角地砖.jpg`，那张图已经不在工程里了
#   ⇒ 候选全部加载失败 ⇒ 退回深色纯色底，"背景图就没了"。现在整段照 `Menu.gd` 的口径来：
#   候选清单（新封面在最前）+ `COVER_VIEW_X` 取景 + 渐变遮罩，三个页面看起来一致。
const COVER_BG_CANDIDATES := [
	"res://assets/界面/封面.png",
	"res://assets/美术资源/背景/界面背景_六角地砖.jpg",   # 旧图（若回归仍可作兜底）
	"res://assets/美术资源/背景/酒桌封面.png",
	"res://assets/美术资源/背景/酒馆封面.png",
]

const COVER_VIEW_X := 0.30   # 横向取景：0 = 贴最左 / 0.5 = 居中（与主菜单一致）

# 封面背景图：等比裁切铺满整屏（候选都缺图时返回 null，由纯色底兜底）。
# 返回**裁剪容器**：里面那张图按"铺满"放大后可能比屏幕宽，容器把超出屏幕的部分裁掉，取景由 `COVER_VIEW_X` 决定。
func _make_cover_bg() -> Control:
	for path in COVER_BG_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var vs := get_viewport().get_visible_rect().size
		var holder := Control.new()
		holder.set_anchors_preset(Control.PRESET_FULL_RECT)
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不能吃掉英雄池点击/拖动
		holder.clip_contents = true
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.set_anchors_preset(Control.PRESET_TOP_LEFT)
		var tw := float(tex.get_width())
		var th := float(tex.get_height())
		if tw <= 0.0 or th <= 0.0:
			return null
		var sc := maxf(vs.x / tw, vs.y / th)
		rect.size = Vector2(tw * sc, th * sc)
		rect.position = Vector2((vs.x - rect.size.x) * COVER_VIEW_X, (vs.y - rect.size.y) * 0.5)
		holder.add_child(rect)
		return holder
	return null

# 竖向渐变遮罩（与主菜单同款）：中段压暗保可读性，顶部标题与底部留亮
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

func _build() -> void:
	_load_teams()   # 【队伍存档】先把上次的我方/敌方队伍恢复出来，再搭界面（下面 _refresh() 才能显示对）
	var vsize := get_viewport().get_visible_rect().size
	# 背景：深色纯色底 → 界面背景贴图（等比裁切铺满，与主菜单/联机大厅同一张）。
	# 贴图缺失/加载失败 ⇒ 只剩纯色底，不影响页面。
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var cover := _make_cover_bg()
	if cover != null:
		add_child(cover)
	add_child(_make_cover_scrim())   # 【2026-09-28】与主菜单同款的渐变遮罩（背景图可读性）

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
	# 【2026-09-23 用户要求】原来这里左边有个常驻标签「当前编辑：我方」—— **已删**；
	#   改由这两个按钮**自己高亮**表示"当前正在编辑哪一方"：按下态（toggle_mode + button_pressed）
	#   ＋ 暖色字（与标题同色），另一方保持普通字色。切边按钮本来就一眼能看见，不用再占一行字。
	var side_row := HBoxContainer.new()
	side_row.alignment = BoxContainer.ALIGNMENT_CENTER
	side_row.add_theme_constant_override("separation", 16)
	vbox.add_child(side_row)
	for i in 2:
		var sb := Button.new()
		sb.text = "编辑敌方" if i == 1 else "编辑我方"
		sb.toggle_mode = true                      # 用"按下态"当选中标记（纯视觉；点击仍走 pressed → _pick_side）
		sb.focus_mode = Control.FOCUS_NONE
		sb.custom_minimum_size = Vector2(150, 54)
		sb.add_theme_font_size_override("font_size", 20)
		sb.pressed.connect(_pick_side.bind(i))
		side_row.add_child(sb)
		_side_btns.append(sb)

	# 【2026-09-23 用户要求】原来这里有一行计数「我方 N/8   敌方 N/8」—— **整行删除**；
	#   敌方人数**并进下面那一行**（见 `_refresh()` 里 `_status_label` 的「敌方 N/8：…」）。
	#   ⇒ 我方人数不再单独显示（勾选状态看英雄池勾子、首发/替补看下面那排小卡）。

	# 【2026-09-23 用户要求】原来这里有一行「队伍存档（改动即自动保存，重启不丢）：我方 N 名 · 敌方 N 名」
	#   —— 与上面 `_count_label` 的「我方 N/8 敌方 N/8」重复，**整行删除**；存档逻辑本身一个字没动
	#   （`_load_teams()` / `_save_teams()` 照旧：进页自动载入、勾选即写盘、重启不丢，只是不再用一行字报数）。

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 19)
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	# 英雄池筛选行（与普通模式选人页同款：筛选按钮 + 右侧计数）
	# 【2026-09-23 用户要求「自由部署的英雄选人界面换成和普通模式一模一样」】筛选实现共用
	#   `Menu.HeroFilter`（嵌套类）⇒ 按钮文案、弹层、勾选规则、选中配色与普通模式逐字一致。
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

	# 已选英雄队伍（英雄池下方）：与普通模式"卡组预览"同款一行平顶蜂窝小卡。
	# 【2026-09-23 用户要求】「在英雄池下方增加一个已选择英雄队伍，像普通模式那样，
	#   点击英雄可以直接取消选择」⇒ 悬停看属性、**点小卡 = 取消选择**（见 `_on_squad_card_clicked`）。
	#   排列顺序 = 勾选顺序 ⇒ 前 STARTERS 名就是首发（标题行里写明）；只显示当前编辑的那一侧。
	# 【2026-09-23 深夜·用户要求】「队伍列表增加一个清空按钮」⇒ 计数文字与「清空」并排放一行，
	#   就贴在队伍小卡上方（不用再跑到页面底部那个「清空当前队伍」去找；那个按钮照旧保留）。
	var squad_row := HBoxContainer.new()
	squad_row.alignment = BoxContainer.ALIGNMENT_CENTER
	squad_row.add_theme_constant_override("separation", 10)
	vbox.add_child(squad_row)
	_squad_cap = Label.new()
	_squad_cap.add_theme_font_size_override("font_size", 15)
	_squad_cap.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	# ⚠️ 【2026-09-23 修·用户截图「清空把英雄池挤没了」】**自动换行的 Label 放进 HBox 必须给它宽度**：
	#   不写 `SIZE_EXPAND_FILL` 的话，它的最小宽度只有 **1 个字** ⇒ HBox 把它压成"一字一行的竖条"，
	#   那一列的**最小高度**就涨到几十行 ⇒ VBox 只能把可伸缩的英雄池（ScrollContainer）挤成 0 高。
	#   现在：占满剩余宽度 + 文字居中 + **关掉自动换行**（文案短，720 宽下稳放一行）。
	#   ⚠️ 在 VBox 里当独子时不会踩这个坑（VBox 默认把子节点横向拉满）——是**搬进 HBox** 才暴露的。
	_squad_cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_squad_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_squad_cap.autowrap_mode = TextServer.AUTOWRAP_OFF
	squad_row.add_child(_squad_cap)
	_squad_clear_btn = Button.new()
	_squad_clear_btn.text = "清空"
	_squad_clear_btn.custom_minimum_size = Vector2(84, 32)
	_squad_clear_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER   # 行高变化时按钮保持 32 高，不被拉长
	_squad_clear_btn.add_theme_font_size_override("font_size", 16)
	_squad_clear_btn.pressed.connect(_on_squad_clear)
	squad_row.add_child(_squad_clear_btn)
	_squad_host = Control.new()
	_squad_host.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 小卡整行居中（本页其它行也是居中）
	vbox.add_child(_squad_host)
	_refresh_filter_ui()   # 初始文案："共 N 名英雄"（与普通模式选人页同款）

	# 敌方操控方式 + AI 难度（沙箱专用）：选 AI 时不启用双控，敌方回合由 AI 跑
	var opt_row := HBoxContainer.new()
	opt_row.alignment = BoxContainer.ALIGNMENT_CENTER
	opt_row.add_theme_constant_override("separation", 12)
	vbox.add_child(opt_row)
	var ctl_label := Label.new()
	ctl_label.text = "敌方操控："
	ctl_label.add_theme_font_size_override("font_size", 18)
	ctl_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	opt_row.add_child(ctl_label)
	var ctl_opt := OptionButton.new()
	ctl_opt.add_item("手动（你操控双方）")
	ctl_opt.add_item("AI（电脑操控敌方）")
	ctl_opt.select(0)
	ctl_opt.custom_minimum_size = Vector2(200, 40)
	ctl_opt.add_theme_font_size_override("font_size", 17)
	ctl_opt.item_selected.connect(func(i: int):
		_enemy_ai = (i == 1)
		if _diff_opt != null:
			_diff_opt.disabled = not _enemy_ai
		_refresh())
	opt_row.add_child(ctl_opt)
	var diff_label := Label.new()
	diff_label.text = "AI 难度："
	diff_label.add_theme_font_size_override("font_size", 18)
	diff_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	opt_row.add_child(diff_label)
	_diff_opt = OptionButton.new()
	for n in AI_DIFF_NAMES:
		_diff_opt.add_item(n)
	_diff_opt.select(clampi(GameState.ai_difficulty, 0, AI_DIFF_NAMES.size() - 1))
	_diff_opt.custom_minimum_size = Vector2(130, 40)
	_diff_opt.add_theme_font_size_override("font_size", 17)
	_diff_opt.disabled = true   # 敌方手动操控时用不到
	_diff_opt.item_selected.connect(func(i: int):
		GameState.ai_difficulty = i
		_refresh())
	opt_row.add_child(_diff_opt)

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
# 【2026-09-23 用户要求】筛选也用普通模式那一套：**同一个实现** `Menu.HeroFilter`（嵌套类），
#   连按钮文案/弹层/勾选规则/配色都一致 ⇒ 两个界面不会各自漂。本函数只负责"按筛选结果排卡"。
func _build_hex_pool(host: Control) -> void:
	_pool_host = host
	_btns.clear()            # 重建前清掉旧卡引用（筛掉的人不留在表里）
	var ids: Array = _filtered_ids()
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
		card.clicked.connect(_on_pool_card_clicked)
		card.hovered.connect(_on_hex_hovered)   # 悬停弹出英雄属性框（与普通模式选人页同一套格式）
		host.add_child(card)
		_btns[id] = card
		max_x = maxf(max_x, cx + r)
		max_y = maxf(max_y, cy + sq3 * r * 0.5)
	# 筛完一个都不剩：留一块可滚区域放"无符合条件"（别把池压成 0 高）
	if ids.is_empty():
		max_x = avail_w
		max_y = r * 2.0
		var empty := Label.new()
		empty.text = "（没有符合条件的英雄）"
		empty.add_theme_font_size_override("font_size", 20)
		empty.add_theme_color_override("font_color", Color(1.0, 0.8, 0.6))
		empty.position = Vector2(20, 20)
		host.add_child(empty)
	host.custom_minimum_size = Vector2(max_x, max_y)
	host.size = Vector2(max_x, max_y)

# ---- 英雄池筛选（与普通模式**同一个** `Menu.HeroFilter` 实现）----
func _flt() -> Menu.HeroFilter:
	if _filter == null:
		_filter = Menu.HeroFilter.new()
		_filter.host = self
		_filter.on_changed = func():
			_rebuild_pool()
			_refresh_filter_ui()
		_filter.shown_count = func() -> int:
			return _filtered_ids().size()
	return _filter

# 卡池顺序：按种族分组（人族→机械→兽族→精灵→魔族）、同种族按 hero_id；再按筛选条件过滤。
# ⚠️ 这段排序与 `Menu._pool_ids()` 逐字一致（用户要求"两个界面一模一样"）。
func _filtered_ids() -> Array:
	var ids: Array = DataRegistry.heroes.keys()
	ids.sort_custom(func(a: String, b: String):
		var da := DataRegistry.get_hero(a)
		var db := DataRegistry.get_hero(b)
		var ra := da.race if da != null else 99
		var rb := db.race if db != null else 99
		if ra != rb:
			return ra < rb
		return a < b)
	var out: Array = []
	for id in ids:
		if _flt().passes(String(id)):
			out.append(id)
	return out

# 筛选条件变化后整块重建卡池（与普通模式同做法：只重排池子，已选队伍不变）
func _rebuild_pool() -> void:
	if _pool_host == null or not is_instance_valid(_pool_host):
		return
	_hide_tooltip()
	for c in _pool_host.get_children():
		_pool_host.remove_child(c)
		c.queue_free()
	_build_hex_pool(_pool_host)
	if _pool_scroll != null and is_instance_valid(_pool_scroll):
		_pool_scroll.scroll_vertical = 0   # 筛完回到池顶
	_refresh()   # 重新按"当前队伍已选"上选中状态

# 池上方计数 + 筛选按钮文案（弹层内计数由 `HeroFilter.refresh_count()` 自己刷）
func _refresh_filter_ui() -> void:
	var total := DataRegistry.heroes.size()
	if _filter_btn != null and is_instance_valid(_filter_btn):
		_filter_btn.text = _flt().button_text()
	if _filter_info != null and is_instance_valid(_filter_info):
		if not _flt().is_active():
			_filter_info.text = "共 %d 名英雄" % total
		else:
			var shown := _filtered_ids().size()
			var hidden_sel := 0
			for id in _cur():
				if not _filtered_ids().has(id):
					hidden_sel += 1
			var extra := "（%d 名已选被隐藏，队伍不变）" % hidden_sel if hidden_sel > 0 else ""
			_filter_info.text = "筛选后 %d / %d 名%s" % [shown, total, extra]
	_flt().refresh_count()

func _open_filter() -> void:
	_hide_tooltip()
	_flt().open()

# 触屏拖动滚动英雄池（模拟器/手机上原生触摸拖动不总生效，与普通模式同处理）
func _input(ev: InputEvent) -> void:
	if _pool_scroll == null or not _pool_scroll.is_visible_in_tree():
		return
	if ev is InputEventScreenTouch:
		var st := ev as InputEventScreenTouch
		if st.pressed:
			_pool_touch_down = _pool_scroll.get_global_rect().has_point(st.position)
			_hide_tooltip()   # 手指按下先收起属性框（轻点松开后由点击重新弹出）
		else:
			_pool_touch_down = false
	elif _pool_touch_down and ev is InputEventScreenDrag:
		var sd := ev as InputEventScreenDrag
		_pool_scroll.scroll_vertical = int(_pool_scroll.scroll_vertical - sd.relative.y)

func _pick_side(s: int) -> void:
	_side = s
	_refresh()

func _toggle(id: String) -> void:
	_show_detail(id)   # 点选英雄同时弹属性框（与普通模式一致：点一下就能看属性）
	var arr := _cur()
	if arr.has(id):
		arr.erase(id)
	else:
		if arr.size() >= TEAM_SIZE:
			_status_label.text = "每队上限 %d 人（前 %d 首发、其余替补）。" % [TEAM_SIZE, STARTERS]
			(_btns[id] as HexCard).set_selected(false)
			return
		arr.append(id)
	_save_teams()   # 【队伍存档】勾/取消立刻写盘（我方、敌方各存各的）
	_refresh()

func _refresh() -> void:
	# 【2026-09-23 用户要求 + 实机反馈】「当前编辑：…」那行删掉后，改由这两个按钮自己高亮。
	#   ⚠️ 第一版**实机看不到高亮**（用户报「按钮没有高亮」），两个原因：
	#     ① 只改了 `font_color`，而**按下态的按钮字色由 `font_pressed_color` 决定**
	#        （主题 `theme/tavern_theme.tres` 里它是近白 `Color(1,1,1,1)`）⇒ 覆盖根本没生效；
	#     ② 主题的 `sb_pressed` 只是把底板 `modulate_color` 压到 0.82（暗一点点），远看几乎没差别。
	#   ⇒ 现在三管齐下：① 按下态字色（`font_pressed_color` / `font_hover_pressed_color`）也改成暖金；
	#     ② 选中方**加亮**（`modulate` > 1）、另一方**压暗**（≈0.62）——`modulate` 画在主题样式之后，
	#        主题盖不住，且两边亮度差 ~2 倍，一眼能看出；③ 仍保留 `button_pressed`（维持"按下"这块板的语义）。
	for i in _side_btns.size():
		var sb2: Button = _side_btns[i]
		if sb2 == null or not is_instance_valid(sb2):
			continue
		var active := i == _side
		var gold := Color(1, 0.85, 0.5)
		sb2.button_pressed = active
		sb2.add_theme_color_override("font_color", gold if active else Color(0.9, 0.92, 1.0))
		sb2.add_theme_color_override("font_hover_color", gold if active else Color(1, 0.96, 0.8))
		sb2.add_theme_color_override("font_pressed_color", gold)
		sb2.add_theme_color_override("font_hover_pressed_color", gold)
		sb2.add_theme_color_override("font_focus_color", gold if active else Color(1, 1, 1))
		sb2.modulate = Color(1.25, 1.16, 0.92) if active else Color(0.62, 0.66, 0.76)
	# 【2026-09-23 用户要求】原来这里刷「我方 N/8   敌方 N/8」计数行 —— **已删**，敌方人数并进下面那行。
	# 我方至少 MIN_PLAYER 名；敌方可不选（0 名）→ 开局自动随机 8 名
	var player_ok := _sel_p.size() >= MIN_PLAYER and _sel_p.size() <= TEAM_SIZE
	var enemy_ok := _sel_e.size() == 0 or _sel_e.size() <= TEAM_SIZE
	_start_btn.disabled = not (player_ok and enemy_ok)
	for id in _btns.keys():
		(_btns[id] as HexCard).set_selected(_cur().has(id))
	# 【2026-09-23 用户要求】原来队伍不合法时会把状态块换成「请组建我方队伍：最少 N 名（上限…)。
	#   当前先编辑 X。」（还可能带第二行「敌方未选择：开局将自动随机 8 名。」）—— **整块删除**。
	#   随后用户又点名删掉「敌方操控：…」这一行 —— 它与上面那一行的**下拉框**重复
	#   （下拉框本身就写着「手动（你操控双方）/ AI（电脑操控敌方）」，旁边还有「AI 难度：」控件）
	#   ⇒ 状态块现在**只剩一行**，且把**敌方人数**并了进来：「敌方 N/8：…」。
	#   ⚠️ 副作用（用户明确要求，故保留）：队伍不合法时
	#   开始按钮照样禁用，但屏幕上不再有一行字解释原因；"每队上限 N 人"那种**操作反馈**仍然保留（见 `_toggle()`）。
	_status_label.text = "敌方 %d/%d：%s" % [_sel_e.size(), TEAM_SIZE,
		("未选择（开局随机 8 名）" if _sel_e.size() == 0 else _names(_sel_e))]

	_refresh_squad()
	# 【2026-09-23 用户要求】原来这里刷新「队伍存档（…）：我方 N 名 · 敌方 N 名」那一行，**已删整行**。

# ---- 队伍存档读写（我方 / 敌方各 1 组，分开存）----
# 进本页时自动载入；`_toggle()` / `_on_clear()` 改动后自动写盘。
func _load_teams() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(TEAM_SAVE_PATH) != OK:
		return   # 没有存档（第一次进来）⇒ 保持两边空队伍
	_sel_p = _sanitize_team(cfg.get_value("quicktest", "player", []))
	_sel_e = _sanitize_team(cfg.get_value("quicktest", "enemy", []))

func _save_teams() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("quicktest", "player", _sel_p)
	cfg.set_value("quicktest", "enemy", _sel_e)
	var err := cfg.save(TEAM_SAVE_PATH)
	if err != OK:
		print("自由部署队伍存档跳过（无法写入 user://）: ", err)

# 回读存档时清洗一遍（存档被手改过 / 英雄被删过也不会把页面搞坏）：
# 丢掉已不存在的英雄、去重、截到 TEAM_SIZE。顺序保持不变（= 前 3 名首发）。
func _sanitize_team(raw: Array) -> Array[String]:
	var out: Array[String] = []
	for v in raw:
		if out.size() >= TEAM_SIZE:
			break
		var id := String(v)
		if out.has(id) or DataRegistry.get_hero(id) == null:
			continue
		out.append(id)
	return out

# ---- 英雄池下方的"已选英雄队伍"（与普通模式卡组预览同款；点小卡取消选择）----
func _refresh_squad() -> void:
	if _squad_cap == null or _squad_host == null:
		return
	var ids := _cur()
	var side_name := "敌方" if _side == 1 else "我方"
	if ids.is_empty():
		_squad_cap.text = "%s队伍：空 —— 点上面英雄池的卡加入（前 %d 名首发，其余替补）" % [side_name, STARTERS]
	else:
		_squad_cap.text = "%s队伍 %d/%d —— 点小卡可取消选择（前 %d 名首发，其余替补）" % [side_name, ids.size(), TEAM_SIZE, STARTERS]
	if _squad_clear_btn != null and is_instance_valid(_squad_clear_btn):
		_squad_clear_btn.disabled = ids.is_empty()   # 空队伍时清空没意义 ⇒ 灰掉
	_build_squad_preview(ids)

func _build_squad_preview(ids: Array) -> void:
	for c in _squad_host.get_children():
		_squad_host.remove_child(c)
		c.queue_free()
	if ids.is_empty():
		_squad_host.custom_minimum_size = Vector2.ZERO
		_squad_host.size = Vector2.ZERO
		return
	# 布局算式与 `Menu._build_deck_preview()` 一致：一行平顶蜂窝，卡数多时自动缩小
	var avail: float = get_viewport().get_visible_rect().size.x - 80.0
	var n := ids.size()
	var r: float = minf(46.0, maxf(avail / (2.0 + float(n - 1) * 1.5), 18.0))
	var sq3 := sqrt(3.0)
	var col_step := 1.5 * r
	var row_step := sq3 * r
	var total_w := 2.0 * r + float(n - 1) * col_step
	var total_h := 2.0 * row_step
	_squad_host.custom_minimum_size = Vector2(total_w, total_h)
	_squad_host.size = Vector2(total_w, total_h)
	for i in n:
		var hid := String(ids[i])
		var def := DataRegistry.get_hero(hid)
		if def == null:
			continue
		var cx := r + float(i) * col_step
		var cy := r + (row_step / 2.0 if i % 2 == 1 else 0.0)
		var card := HexCard.new(def, hid, r)
		card.position = Vector2(cx - r, cy - row_step / 2.0)
		card.hovered.connect(_on_hex_hovered)          # 悬停看属性（与英雄池同一套属性框）
		card.clicked.connect(_on_squad_card_clicked)   # 点小卡 = 取消选择
		_squad_host.add_child(card)

# 点队伍里的小卡 = 直接从队伍里去掉这个英雄（与普通模式"点卡组小卡"同一手感）。
# 不复用 `_toggle()`：那个是"点一下弹属性框"的加入手感，这里是明确的删除动作。
# 【2026-09-23 深夜·用户要求】队伍列表里的「清空」：清掉**当前编辑的那一侧**。
#   走同一个 `_on_clear()`（清空 + 写存档 + 刷新）⇒ 与底部那个「清空当前队伍」行为逐字一致。
func _on_squad_clear() -> void:
	_on_clear()

func _on_squad_card_clicked(id: String) -> void:
	var arr := _cur()
	if not arr.has(id):
		return
	arr.erase(id)
	_hide_tooltip()   # 这张小卡马上被重建、不会再发 mouse_exited ⇒ 属性框先收起，反馈更干净
	_save_teams()     # 【队伍存档】改动即写盘
	_refresh()        # 计数 + 池子高亮 + 重建这一行（被点的卡随之消失）

func _names(arr: Array) -> String:
	var ns: Array[String] = []
	for id in arr:
		ns.append(DataRegistry.heroes[id].display_name)
	return "、".join(ns)

func _on_clear() -> void:
	_cur().clear()
	_save_teams()   # 「清空当前队伍」= 同时清掉该侧存档（自动保存）
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
	# 敌方操控：勾了 AI 就关掉双控（敌方回合跑 AI，难度取 GameState.ai_difficulty）；
	# 不勾则保持双控（双方回合都由玩家操控）
	GameState.dual_control = not _enemy_ai
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
