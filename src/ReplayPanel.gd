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

var battle = null
var _play_btn: Button = null
var _speed_btn: Button = null
var _bar: PanelContainer = null   # 控制条本体（宽度按内容自适应，见 `_layout_bar()`）

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
	# 速度 1× → 2× → 4× → 1×（回放倍速 = 全局 time_scale，动画/停顿一起变快）
	_speed_btn = _btn("1×", 58.0)
	_speed_btn.pressed.connect(_cycle_speed)
	box.add_child(_speed_btn)
	# 【2026-09-28 用户要求】「录像能分享成视频吗」⇒ 加「导出」：把这一条录像重播一遍并抓帧存盘，
	# 有 ffmpeg 就合成 mp4（实现见 `src/ReplayExporter.gd`，进度写在窗口标题上）。
	var exp := _btn("导出", 64.0)
	exp.pressed.connect(_on_export)
	box.add_child(exp)
	var quit := _btn("返回", 70.0)
	quit.pressed.connect(func(): battle.replay_quit())
	box.add_child(quit)
	# 贴屏幕下方（回合横幅在屏幕中央，不打架），按视口宽度居中
	_layout_bar(vsize)
	refresh()

## 控制条宽度 = **内容宽度**（原来写死 600，会把内容挤掉一点）：
## 六个按钮的最小宽度 + 间距 + 面板内边距之和，居中贴屏幕下方。没有读数 ⇒ 不存在"留一块空位"。
func _layout_bar(vsize: Vector2) -> void:
	if _bar == null or not is_instance_valid(_bar):
		return
	var w: float = minf(_bar.get_combined_minimum_size().x, vsize.x - 12.0)
	_bar.size = Vector2(w, 64.0)
	_bar.position = Vector2((vsize.x - w) / 2.0, vsize.y - _bar.size.y - 8.0)

func _btn(txt: String, w: float) -> Button:
	var b := Button.new()
	b.text = txt
	b.custom_minimum_size = Vector2(w, 48)
	b.add_theme_font_size_override("font_size", 18)
	b.focus_mode = Control.FOCUS_NONE
	UiDice.detach(b)   # 回放控制条上不挂悬浮骰子
	return b

## 倍速循环：1× → 2× → 4× → **0.5×** → 1×（【2026-09-28 用户要求】加 0.5× 慢放档）。
func _cycle_speed() -> void:
	var cur: float = float(battle._replay_speed)
	var nxt := 1.0
	if cur < 0.75:
		nxt = 1.0
	elif cur < 1.5:
		nxt = 2.0
	elif cur < 3.0:
		nxt = 4.0
	else:
		nxt = 0.5
	battle.replay_set_speed(nxt)

## 倍速按钮文字：整数档写「2×」，半档写「0.5×」。
func _speed_text(sp: float) -> String:
	if is_equal_approx(sp, float(int(sp))):
		return "%d×" % int(sp)
	return "%.1f×" % sp

## 「导出」：把这一条录像导成视频（抓帧 → 有 ffmpeg 就合成 mp4）。导出期间按钮本身不响应第二次点击。
func _on_export() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if battle.has_method("replay_is_exporting") and bool(battle.replay_is_exporting()):
		return
	battle.replay_export_video()

func refresh() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	if _play_btn != null:
		_play_btn.text = "继续" if bool(battle._replay_paused) else "暂停"
	if _speed_btn != null:
		_speed_btn.text = _speed_text(float(battle._replay_speed))
