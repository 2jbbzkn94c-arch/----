class_name VolumeControl
extends Control
## 右上角音效音量调节控件：自绘喇叭图标，点击弹出音量滑条面板（0-100%）。
## 实际音量由 AudioManager 统一管理并持久化（user://audio.cfg），本控件只读写它。
## 用法：VolumeControl.new() 后 add_child，再调 place_top_right(视口尺寸)。
## 兼容两处宿主：战斗 HUD 顶栏（CanvasLayer 内）与主菜单（普通 Control 树）——
## 弹层放在独立 CanvasLayer(70) 上，保证盖过宿主其它 UI。

const BTN_W := 76.0
const BTN_H := 40.0
const PANEL_W := 250.0
const LAYER := 70

var _layer: CanvasLayer = null
var _panel: PanelContainer = null
var _slider: HSlider = null
var _val_label: Label = null
var _vol := 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(BTN_W, BTN_H)
	size = Vector2(BTN_W, BTN_H)
	_vol = AudioManager.get_volume()
	queue_redraw()

# 放视口右上角（宿主为满屏 Control/CanvasLayer 时坐标即视口坐标）
func place_top_right(vsize: Vector2, margin_x := 8.0, margin_y := 7.0) -> void:
	position = Vector2(vsize.x - margin_x - BTN_W, margin_y)
	size = Vector2(BTN_W, BTN_H)

# 放视口右下角（如战斗界面，与左下角喊话按钮对称）
func place_bottom_right(vsize: Vector2, margin_x := 10.0, margin_b := 22.0) -> void:
	position = Vector2(vsize.x - margin_x - BTN_W, vsize.y - margin_b - BTN_H)
	size = Vector2(BTN_W, BTN_H)

# ---- 自绘喇叭图标 ----
func _draw() -> void:
	var muted := _vol <= 0.001
	var icon_c := Color(1.0, 0.9, 0.55, 0.95)
	if muted:
		icon_c = Color(1.0, 0.5, 0.45, 0.95)
	var midy := size.y / 2.0
	# 喇叭箱体 + 出声锥口
	var body := PackedVector2Array([
		Vector2(6, midy - 9), Vector2(17, midy - 9), Vector2(17, midy + 9), Vector2(6, midy + 9),
	])
	draw_colored_polygon(body, icon_c)
	var mouth := PackedVector2Array([
		Vector2(17, midy - 9), Vector2(26, midy - 14), Vector2(26, midy + 14), Vector2(17, midy + 9),
	])
	draw_colored_polygon(mouth, icon_c)
	if muted:
		# 静音：红色斜杠
		draw_line(Vector2(29, midy - 11), Vector2(55, midy + 11), Color(1.0, 0.4, 0.35, 0.95), 3.0, true)
		return
	# 按音量画 0-3 道声波弧
	var arcs := clampi(int(ceil(_vol * 3.0)), 0, 3)
	var from := -0.62
	var to := 0.62
	for i in arcs:
		var rad := 7.0 + float(i) * 5.0
		var col := Color(icon_c.r, icon_c.g, icon_c.b, maxf(0.95 - float(i) * 0.22, 0.35))
		draw_arc(Vector2(34.0, midy), rad, from, to, 14, col, 2.0, true)

func _gui_input(ev: InputEvent) -> void:
	# 与全项目一致：触摸由 Godot 转成鼠标左键事件（安卓/iOS 默认开启），只处理鼠标事件避免双触发
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_toggle()
	accept_event()

func _toggle() -> void:
	if _layer != null and is_instance_valid(_layer):
		_close_panel()
	else:
		_open_panel()

# ---- 弹层（独立 CanvasLayer，全屏遮罩点外面即收起）----
func _open_panel() -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	var layer := CanvasLayer.new()
	layer.layer = LAYER
	add_child(layer)
	_layer = layer
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_overlay_input)
	layer.add_child(overlay)
	# 半透明压暗背景（只轻微压暗，聚焦滑条）
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.22)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	# 面板：右上角喇叭按钮下方
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.16, 0.95)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 0.85, 0.5, 0.8)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(panel)
	_panel = panel
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var title := Label.new()
	title.text = "音效音量"
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.step = 1.0
	slider.custom_minimum_size = Vector2(150, 40)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value = clampf(roundf(_vol * 100.0), 0.0, 100.0)
	slider.value_changed.connect(_on_volume_changed)
	# 松手后播一声"选择"音效，让玩家听到调节效果
	slider.drag_ended.connect(func(_changed: bool): AudioManager.play("select"))
	row.add_child(slider)
	_slider = slider
	var val := Label.new()
	val.text = _pct_text(int(slider.value))
	val.add_theme_font_size_override("font_size", 18)
	val.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.custom_minimum_size = Vector2(52, 40)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)
	_val_label = val
	var hint := Label.new()
	hint.text = "0 为静音 · 点喇叭/面板外收起"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)
	# 定位：与喇叭按钮同侧对齐；按钮贴近上/下边缘时弹层自动改向另一侧，避免出屏
	panel.reset_size()
	var pw: float = maxf(panel.get_combined_minimum_size().x, PANEL_W)
	panel.custom_minimum_size = Vector2(pw, 0)
	panel.size = Vector2(pw, panel.get_combined_minimum_size().y)
	var gp := get_global_position()
	var gv := get_viewport().get_visible_rect().size
	var px := gp.x + BTN_W - pw
	px = clampf(px, 6.0, maxf(6.0, gv.x - pw - 6.0))
	var ph: float = panel.size.y
	var py := gp.y + BTN_H + 6.0
	if py + ph > gv.y - 6.0:
		py = maxf(6.0, gp.y - ph - 6.0)   # 贴底时向上弹
	panel.position = Vector2(px, py)

func _pct_text(p: int) -> String:
	if p <= 0:
		return "静音"
	return "%d%%" % p

func _on_volume_changed(v: float) -> void:
	var vol := clampf(v / 100.0, 0.0, 1.0)
	AudioManager.set_volume(vol)
	_vol = vol
	if _val_label != null and is_instance_valid(_val_label):
		_val_label.text = _pct_text(int(roundf(v)))
	queue_redraw()

func _on_overlay_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_close_panel()
	accept_event()

func _close_panel() -> void:
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_panel = null
	_slider = null
	_val_label = null
	queue_redraw()
