extends CanvasLayer
## 回放控制条（单机录像回放时由 `Battle._replay_start()` 建出来）。
##
## 【2026-09-27 用户要求】"可以暂停，可以到上下回合，可以倍速"⇒ 控制条只放这几类按钮：
##   开局 · 上回合 · 播放/暂停 · 下回合 · 速度（1×/2×/4×）· 返回
##   （**不加**任何说明性小字，口径见 AGENTS.md「界面文案」。）
##   【2026-09-28 用户要求】「录像下面的状态栏里的字"部署画面 1/3"删掉」→「怎么还显示第 1 回合…」
##   ⇒ **读数字整条删掉**（原来这里报「部署画面 i/n」/「第 N 回合 · 我方/敌方 i/n」），
##   控制条现在只有按钮、宽度贴着按钮走（见 `_layout_bar()`）。
##   回合号/回合进度仍在**屏幕顶栏**（`HUD._round_label`：「第 N 回合 · 蓝方/红方回合」）。
##
## 为什么独立成文件：与 `EnemyReplay` / `BoardView` 同一类——回放是"流程 + 控件"，不是对局规则。
## Battle 只负责把每一段重演出来，控件只管发号施令（真正读标志位的是 Battle）。
##
## 依赖方向：ReplayPanel → Battle（动态调用其回放方法，battle 故意未定型）。

const LAYER := 70   # 高于 HUD(50)：压在战场界面之上
const ReplayExporterScript := preload("res://src/ReplayExporter.gd")   # 只为读/写"保存位置"的记忆
## 【2026-09-28 用户要求】「把录像的状态调节栏往上挪」：原来贴在最下沿（距底 8px），
##   底边那一圈在播放器里会被进度条/按钮压住、画面里也显得贴边。现在抬高这么多像素。
const BAR_BOTTOM_MARGIN := 128.0

var battle = null
var _play_btn: Button = null
var _speed_btn: Button = null
var _rec_btn: Button = null       # 「开始录制 / 停止录制」（同一条按钮切换文字）
var _speed_menu: PanelContainer = null   # 倍速选择框（点倍速按钮弹出，见 `_open_speed_menu()`）
var _bar: PanelContainer = null   # 控制条本体（宽度按内容自适应，见 `_layout_bar()`）
var _saved: PanelContainer = null # 停止录制后的"保存位置"弹框
var _saved_file_label: Label = null
var _saved_dir_label: Label = null

func _init(battle_) -> void:
	battle = battle_

func _ready() -> void:
	layer = LAYER
	var vsize := get_viewport().get_visible_rect().size
	var bar := PanelContainer.new()
	_bar = bar
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.1, 0.88)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.set_corner_radius_all(10)
	bar.add_theme_stylebox_override("panel", sb)
	add_child(bar)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	bar.add_child(box)
	var first := _btn("开局", 64.0)
	first.pressed.connect(func(): battle.replay_seek_frame(0))
	box.add_child(first)
	var prev := _btn("上回合", 78.0)
	prev.pressed.connect(func(): battle.replay_seek_frame(battle._replay_frame - 1))
	box.add_child(prev)
	_play_btn = _btn("暂停", 78.0)
	_play_btn.pressed.connect(func(): battle.replay_set_paused(not battle._replay_paused))
	box.add_child(_play_btn)
	var nxt := _btn("下回合", 78.0)
	nxt.pressed.connect(func(): battle.replay_seek_frame(battle._replay_frame + 1))
	box.add_child(nxt)
	# 速度：点开一个**选择框**（用户 2026-09-28 要求「点击倍速按钮，弹出来选择框，0.5x 在上，加速在下」）
	#   —— 原来是"点一下循环下一档"，看不到有哪些档、也回不去指定档。
	_speed_btn = _btn("1×", 58.0)
	_speed_btn.pressed.connect(_open_speed_menu)
	box.add_child(_speed_btn)
	# 【2026-09-28 用户要求】「状态栏改为开始录制，点击后变成停止录制」：同一条按钮切换。
	#   停止后由 Battle 调 `show_saved_popup()` 弹出"录像保存位置"（位置记忆见 `ReplayExporter.rec_dir()`）。
	_rec_btn = _btn("开始录制", 104.0)
	_rec_btn.pressed.connect(_on_record_toggle)
	box.add_child(_rec_btn)
	var quit := _btn("返回", 70.0)
	quit.pressed.connect(func(): battle.replay_quit())
	box.add_child(quit)
	# 距屏幕下沿 `BAR_BOTTOM_MARGIN`，按视口宽度居中；窗口尺寸变了跟着重排（放大窗口导出时也要居中）
	_layout_bar(vsize)
	get_viewport().size_changed.connect(func(): _layout_bar(get_viewport().get_visible_rect().size))
	refresh()

## 控制条宽度 = **内容宽度**（原来写死 600，会把内容挤掉一点）：
## 六个按钮的最小宽度 + 间距 + 面板内边距之和，居中，距屏幕下沿 `BAR_BOTTOM_MARGIN` 像素。
## 没有读数 ⇒ 不存在"留一块空位"。
func _layout_bar(vsize: Vector2) -> void:
	if _bar == null or not is_instance_valid(_bar):
		return
	_close_speed_menu()   # 尺寸变了：选择框位置会失效，直接收起（下次点开重新算）
	var w: float = minf(_bar.get_combined_minimum_size().x, vsize.x - 12.0)
	_bar.size = Vector2(w, 64.0)
	_bar.position = Vector2((vsize.x - w) / 2.0, vsize.y - _bar.size.y - BAR_BOTTOM_MARGIN)

func _btn(txt: String, w: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(w, 48)
	b.add_theme_font_size_override("font_size", 18)
	b.focus_mode = Control.FOCUS_NONE
	UiDice.detach(b)   # 回放控制条上不挂悬浮骰子
	return b

## 倍速选择框（用户 2026-09-28 要求）：点倍速按钮弹出，**0.5× 在最上、加速依次在下**；
## 当前档高亮；选一档就设上并收起；再点一次按钮、或窗口尺寸变了也收起。
## 贴在倍速按钮**正上方**（不挡控制条）。
const SPEED_CHOICES: Array = [0.5, 1.0, 2.0, 4.0]

func _open_speed_menu() -> void:
	if _speed_menu != null and is_instance_valid(_speed_menu):
		_close_speed_menu()   # 再点一次 = 收起
		return
	if battle == null or not is_instance_valid(battle):
		return
	var menu := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.1, 0.94)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.set_corner_radius_all(10)
	menu.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	menu.add_child(box)
	var cur := float(battle._replay_speed)
	for sp in SPEED_CHOICES:
		var b := _btn(_speed_text(float(sp)), 96.0)
		if is_equal_approx(float(sp), cur):
			b.add_theme_color_override("font_color", Color(1.0, 0.88, 0.5))   # 当前档
		b.pressed.connect(func():
			battle.replay_set_speed(float(sp))
			_close_speed_menu()
			refresh())
		box.add_child(b)
	add_child(menu)
	menu.size = menu.get_combined_minimum_size()
	var vsize := get_viewport().get_visible_rect().size
	var bx := 4.0
	if _speed_btn != null and is_instance_valid(_speed_btn):
		bx = clampf(_speed_btn.global_position.x, 4.0, vsize.x - menu.size.x - 4.0)
	menu.position = Vector2(bx, maxf(4.0, _bar.position.y - menu.size.y - 8.0))
	_speed_menu = menu

func _close_speed_menu() -> void:
	if _speed_menu != null and is_instance_valid(_speed_menu):
		_speed_menu.queue_free()
	_speed_menu = null

## 倍速按钮文字：整数档写「2×」，半档写「0.5×」。
func _speed_text(sp: float) -> String:
	if is_equal_approx(sp, float(int(sp))):
		return "%d×" % int(sp)
	return "%.1f×" % sp

## 【2026-09-28 用户要求】「开始录制 / 停止录制」：一条按钮切换。停止后 Battle 会弹"保存位置"。
func _on_record_toggle() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if bool(battle.replay_is_recording()):
		battle.replay_record_stop()
	else:
		battle.replay_record_start()
	refresh()
	_layout_bar(get_viewport().get_visible_rect().size)

## 停止录制后弹出「保存位置」：显示成品路径 + 记住的位置，三个按钮（打开文件夹 / 改保存位置… / 好）。
## 【2026-09-28 用户要求】「停止录制后弹出保存录像位置，录像位置需要有记忆」—— 记忆落在
## `ReplayExporter.rec_dir()/set_rec_dir()`（`user://replay_video.cfg`），下次录制直接用那一处。
func show_saved_popup(path: String) -> void:
	_close_saved_popup()
	var vsize := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.1, 0.94)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	sb.set_corner_radius_all(12)
	sb.border_color = Color(0.9, 0.78, 0.45, 0.9)
	sb.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var title := Label.new()
	title.text = "录像已保存"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	# 【2026-09-28 用户报「弹框格式不对，留白太多」】原来给路径标签写死了 560 的最小宽度
	#   ⇒ 短路径右边空一大块。现在**按内容收紧**：先让它自然宽（能一行放下就一行），
	#   只有整框会超出屏幕时才反过来给它限宽、强制换行（长路径仍看得全）。
	_saved_file_label = Label.new()
	_saved_file_label.text = path
	_saved_file_label.add_theme_font_size_override("font_size", 14)
	_saved_file_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_saved_file_label)
	_saved_dir_label = Label.new()
	_saved_dir_label.text = "保存位置：%s" % ReplayExporterScript.rec_dir()
	_saved_dir_label.add_theme_font_size_override("font_size", 14)
	_saved_dir_label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	_saved_dir_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_saved_dir_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)
	var open := _btn("打开文件夹", 116.0)
	open.pressed.connect(func():
		OS.shell_open(path.get_base_dir())
		_close_saved_popup())
	row.add_child(open)
	var chg := _btn("改保存位置…", 132.0)
	chg.pressed.connect(_pick_rec_dir)
	row.add_child(chg)
	var ok := _btn("好", 64.0)
	ok.pressed.connect(_close_saved_popup)
	row.add_child(ok)
	add_child(panel)
	# 先按内容量一次；超宽才给两行文字限宽（按钮那行是硬下限，不再压）
	var msz := panel.get_combined_minimum_size()
	if msz.x > vsize.x - 40.0:
		var cap := maxf(vsize.x - 40.0 - 28.0, 240.0)
		_saved_file_label.custom_minimum_size = Vector2(cap, 0)
		_saved_dir_label.custom_minimum_size = Vector2(cap, 0)
		msz = panel.get_combined_minimum_size()
	panel.size = Vector2(minf(msz.x, vsize.x - 40.0), msz.y)
	panel.position = Vector2((vsize.x - panel.size.x) / 2.0, (vsize.y - panel.size.y) / 2.0)
	_saved = panel
	AudioManager.play("win")

func _close_saved_popup() -> void:
	if _saved != null and is_instance_valid(_saved):
		_saved.queue_free()
	_saved = null
	_saved_file_label = null
	_saved_dir_label = null

## 「改保存位置…」：系统文件夹选择框（Windows 原生），选完**记住**并刷新弹框上的那行字。
func _pick_rec_dir() -> void:
	var d := FileDialog.new()
	d.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	d.access = FileDialog.ACCESS_FILESYSTEM
	d.use_native_dialog = true
	d.current_dir = ReplayExporterScript.rec_dir()
	d.dir_selected.connect(func(p: String):
		ReplayExporterScript.set_rec_dir(p)
		if _saved_dir_label != null and is_instance_valid(_saved_dir_label):
			_saved_dir_label.text = "保存位置：%s" % p
		d.queue_free())
	d.canceled.connect(func(): d.queue_free())
	add_child(d)
	d.popup_centered()

func refresh() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if _play_btn != null:
		_play_btn.text = "继续" if bool(battle._replay_paused) else "暂停"
	if _speed_btn != null:
		_speed_btn.text = _speed_text(float(battle._replay_speed))
	if _rec_btn != null:
		# 【2026-09-28 用户要求】录制开关的文字跟着状态走（开始录制 ↔ 停止录制）
		_rec_btn.text = "停止录制" if bool(battle.replay_is_recording()) else "开始录制"
