extends Node
## 【2026-09-24 用户要求「为所有按钮添加和主界面效果一样的骰子效果」】**全局悬浮骰子**。
##
## 做法：不逐个按钮调用（项目里 Button 有 100+ 个创建点，还有大量运行时生成的弹框 ⇒ 必漏），
##   改成**全局钩子**：`get_tree().node_added` 里发现 `Button`（含 `OptionButton`）就给它挂一颗
##   「鼠标移上去淡入」的六点骰子。效果参数与主菜单**逐字相同**（原来在 `src/Menu.gd::_attach_hover_dice()`，
##   现整段搬到这里、那边已删除，避免同一个按钮挂两颗）。
##
## 三条安全线：
##   ① **headless（跑批/探针/对拍）整段不装** —— 那边会成千上万次实例化 `Main.tscn`，
##      挂几十个 TextureRect 纯属浪费（而且没窗口、悬浮事件也不会发生）；
##   ② 同一个按钮只挂一次（`set_meta("hover_dice", true)` 去重）；
##   ③ 图缺了（`theme/dice_6.png` 不在）或加载失败 ⇒ 整段跳过，按钮本身不受任何影响。
##
## 【2026-09-25 用户要求】两条收窄：
##   · **下拉框（`OptionButton`）一律不挂** —— 它的文字是**左对齐**的（对齐值 0，内容左边距 14），
##     骰子正好压在文字上；用户点名「AI 难度选择下拉框」要去掉。
##   · **放不下就不显示**（`_fits()`）：按按钮自己的字号/文字/图标算出"文字左沿"，
##     骰子右沿 + 8px 空隙还够不着文字才淡入 ⇒ 窄按钮（「?」「筛选」小卡、弹框小按钮）自然没有骰子。
##   · 个别按钮要永久去掉：`UiDice.detach(btn)`（删掉已挂的 + 打 `no_dice` 标记，重新入树也不会再挂）。
##
## 手动调用：`UiDice.attach(btn)` / `UiDice.detach(btn)`（探针/特殊场合用；与自动钩子等价、同样去重）。

const HOVER_DICE_PATH := "res://theme/dice_6.png"
const DICE_INSET_X := 14.0   # 骰子距按钮左边缘的像素（= 牌子边框那一圈，不会压到中间的字）
const DICE_GAP := 8.0        # 骰子右沿到"文字左沿"至少留这么多像素，否则这颗骰子不淡入
const META_KEY := "hover_dice"
const META_CB := "hover_dice_cb"   # 挂在这颗骰子上的三个 lambda（`detach()` 要逐个断开，见那里）
const NO_DICE_KEY := "no_dice"   # `detach()` 打的标记：这个按钮永久不要骰子

var _tex: Texture2D = null
var _tex_tried := false
var _auto := false

func _ready() -> void:
	# headless：不装钩子（省内存、也不碰资源加载）。`attach()` 仍可手动调用。
	if DisplayServer.get_name() == "headless":
		return
	_auto = true
	get_tree().node_added.connect(_on_node_added)
	# autoload 先于主场景就绪 ⇒ 这里只需兜住"已经存在的"（正常情况为空）
	for b in _buttons_under(get_tree().root):
		attach(b)

func _on_node_added(n: Node) -> void:
	if _auto and n is Button:
		attach(n as Button)

## 给一个按钮挂骰子（幂等）。headless 下也可以手动调用（探针验证用）。
func attach(btn: Button) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	if btn is OptionButton:
		return                     # 下拉框文字左对齐 ⇒ 骰子必压字（用户点名去掉）
	if btn.has_meta(META_KEY) or btn.has_meta(NO_DICE_KEY):
		return
	if not _ensure_tex():
		return
	btn.set_meta(META_KEY, true)
	var dice := TextureRect.new()
	dice.name = "HoverDice"
	dice.texture = _tex
	dice.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dice.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dice.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不能吃掉按钮的悬浮/点击
	dice.modulate.a = 0.0
	dice.visible = false
	btn.add_child(dice)
	var place := func() -> void:
		if not is_instance_valid(dice) or not is_instance_valid(btn):
			return
		var d := clampf(btn.size.y - 22.0, 18.0, 36.0)
		dice.size = Vector2(d, d)
		dice.position = Vector2(DICE_INSET_X, (btn.size.y - d) * 0.5)
	var on_enter := func() -> void:
		if not is_instance_valid(dice):
			return
		# ⚠️ 每次悬浮现算（不在 `place()` 里缓存）：按钮文案会在运行时变长
		#   （「开始对战」→「完成编辑」、「筛选」→「筛选（3 项）」…）⇒ 缓存会过期、骰子就压到字上了。
		#   现算只多一次字符串测宽，且只在悬浮时发生。
		if not _fits(btn, dice.size.y):
			return                 # 放不下（会压到字）⇒ 这一颗不淡入
		dice.visible = true
		var tw := dice.create_tween()
		tw.tween_property(dice, "modulate:a", 1.0, 0.12)
	var on_exit := func() -> void:
		if not is_instance_valid(dice):
			return
		var tw := dice.create_tween()
		tw.tween_property(dice, "modulate:a", 0.0, 0.12)
		tw.tween_callback(func(): dice.visible = false)
	# ⚠️ 【2026-09-25·用户实机报错】三个 lambda 都**捕获了这颗骰子** ⇒ 必须在 `detach()` 里逐个断开，
	#   否则骰子被 free 之后按钮再 resized / 悬浮，引擎就报
	#   `Lambda capture at index 0 was freed. Passed "null" instead.`（`gdspeech_lambda_callable.cpp:242`）。
	#   把 Callable 存在骰子自己身上，`detach()` 拿得到（骰子死了就没人再触发 ⇒ 三处一起断）。
	dice.set_meta(META_CB, [place, on_enter, on_exit])
	btn.resized.connect(place)
	place.call()
	btn.mouse_entered.connect(on_enter)
	btn.mouse_exited.connect(on_exit)

## 【2026-09-25 用户要求】把这个按钮上的骰子**永久去掉**：
##   ① 断开挂在按钮三个信号上的 lambda（它们捕获了骰子，不断开就会被 free 后报错，见 `attach()` 末尾）
##   ② 删掉已挂的那颗 + 打 `no_dice` 标记（`attach()` 见到标记直接跳过 ⇒ 弹框重建/重新入树也不会再长出来）。
##   调用时机随意（建好之后调就行；重复调无副作用）。
func detach(btn: Button) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	btn.set_meta(NO_DICE_KEY, true)
	var old := btn.get_node_or_null("HoverDice")
	if old != null and is_instance_valid(old):
		for cb in (old.get_meta(META_CB, []) as Array):
			if not (cb is Callable):
				continue
			if btn.resized.is_connected(cb):
				btn.resized.disconnect(cb)
			if btn.mouse_entered.is_connected(cb):
				btn.mouse_entered.disconnect(cb)
			if btn.mouse_exited.is_connected(cb):
				btn.mouse_exited.disconnect(cb)
		old.queue_free()
	btn.remove_meta(META_KEY)

## 这颗骰子放不放得下：按钮自己的字号/文字/图标算出"文字左沿"，要求
##   `文字左沿 ≥ 骰子左缩进 + 骰子宽 + 空隙`。空文字（纯图标按钮）按图标宽算。
##   ⚠️ 由 `mouse_entered` **每次悬浮现算**（按钮文案运行时可变，缓存会过期）。
func _fits(btn: Button, d: float) -> bool:
	var need := DICE_INSET_X + d + DICE_GAP
	if btn.size.x < need + 16.0:
		return false
	var text_left := 12.0          # 左对齐 / 右对齐：按内容边距兜底（骰子基本都贴到字上）
	var icon_w := 0.0
	if btn.icon != null:
		icon_w = float(btn.icon.get_width()) + 4.0
	if btn.alignment == HORIZONTAL_ALIGNMENT_CENTER:
		var font := btn.get_theme_font("font")
		var fs := btn.get_theme_font_size("font_size")
		var tw := icon_w
		if font != null and btn.text != "":
			tw += font.get_string_size(btn.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		text_left = (btn.size.x - tw) * 0.5
	elif btn.alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		text_left = btn.size.x - icon_w - 12.0
	else:
		text_left = 12.0 + icon_w
	return text_left >= need

func _ensure_tex() -> bool:
	if _tex != null:
		return true
	if _tex_tried:
		return false
	_tex_tried = true
	if not ResourceLoader.exists(HOVER_DICE_PATH):
		return false
	_tex = load(HOVER_DICE_PATH) as Texture2D
	return _tex != null

func _buttons_under(n: Node) -> Array:
	var out: Array = []
	if n is Button:
		out.append(n)
	for c in n.get_children():
		out.append_array(_buttons_under(c))
	return out
