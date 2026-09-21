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
var _enemy_ai := false                     # 敌方是否交给 AI（不勾选=双控，双方都归玩家）
var _diff_opt: OptionButton = null          # AI 难度下拉（敌方为 AI 时生效）
const AI_DIFF_NAMES := ["简单", "普通", "困难", "噩梦"]   # 与 Menu 的四档一致（2026-09-20 删除第 5 档「噩梦+」）

# 测试场里各队可上场的格子（底部行我方 / 第一满行敌方），只放首发 3 个
const PLAYER_CELLS := [Vector2i(0, 6), Vector2i(2, 6), Vector2i(4, 6)]
const ENEMY_CELLS := [Vector2i(0, 1), Vector2i(2, 1), Vector2i(4, 1)]

func _ready() -> void:
	_build()
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

# 界面背景贴图（与主菜单/联机大厅同一张）：按顺序取【第一个能加载的】；全缺图 ⇒ null ⇒ 退回纯色底。
# 换图只需把想用的那张挪到最前（或直接替换文件内容）。
const COVER_BG_CANDIDATES := [
	"res://assets/美术资源/背景/界面背景_六角地砖.jpg",
]

func _make_cover_bg() -> TextureRect:
	for path in COVER_BG_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var r := TextureRect.new()
		r.texture = tex
		r.set_anchors_preset(Control.PRESET_FULL_RECT)
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # 等比裁切铺满，不变形
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE               # 不能吃掉英雄池点击/拖动
		return r
	return null

func _build() -> void:
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
		card.hovered.connect(_on_hex_hovered)   # 悬停弹出英雄属性框（与普通模式选人页同一套格式）
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
		_status_label.text = "我方：%s\n敌方：%s\n敌方操控：%s" % [_names(_sel_p),
			("未选择（开局随机 8 名）" if _sel_e.size() == 0 else _names(_sel_e)),
			("AI（难度 %s）" % AI_DIFF_NAMES[clampi(GameState.ai_difficulty, 0, AI_DIFF_NAMES.size() - 1)] if _enemy_ai else "手动（你操控双方）")]

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
