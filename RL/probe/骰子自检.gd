extends Node
## 【2026-09-24 一次性探针】全局悬浮骰子（`autoload/UiDice.gd`）自检。
##
## 查三件事：
##   ① 手动 `UiDice.attach(btn)` 能挂上（子节点 = 1 个 `HoverDice`、尺寸/位置按按钮高度算）；
##   ② **幂等**：同一个按钮调两次仍只有 1 颗（不会叠两颗）；
##   ③ headless 下**自动钩子**按设计不装（跑批/探针不浪费）—— 新建的按钮不会自动长骰子。
## 输出：`PROBE|...` 行 + `PROBE|END`。

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	print("PROBE|CFG|headless=%s|UiDice=%s" % [str(DisplayServer.get_name() == "headless"), _sha("res://autoload/UiDice.gd")])
	var vbox := VBoxContainer.new()
	vbox.size = Vector2(400, 200)
	add_child(vbox)
	# ① 手动挂（模拟 58 高 / 40 高的按钮）
	var b1 := Button.new()
	b1.text = "单机模式"
	b1.custom_minimum_size = Vector2(280, 58)
	vbox.add_child(b1)
	b1.size = Vector2(280, 58)
	UiDice.attach(b1)
	UiDice.attach(b1)   # 第二次应被去重
	await get_tree().process_frame
	var d1: Node = b1.get_node_or_null("HoverDice")
	print("PROBE|①手动attach|子节点=%d（应为 1）｜有 meta=%s ｜骰子尺寸=%s 位置=%s" % [
		b1.get_child_count(), str(b1.has_meta("hover_dice")),
		str(d1.size) if d1 != null else "-", str(d1.position) if d1 != null else "-"])
	# ② 小按钮（36 高）：骰子按公式 min(36, 36-22=14→夹到 18) = 18
	var b2 := Button.new()
	b2.text = "×"
	b2.custom_minimum_size = Vector2(44, 36)
	vbox.add_child(b2)
	b2.size = Vector2(44, 36)
	UiDice.attach(b2)
	await get_tree().process_frame
	var d2: Node = b2.get_node_or_null("HoverDice")
	print("PROBE|②小按钮|骰子尺寸=%s（公式 clamp(36-22,18,36) ⇒ 18）" % (str(d2.size) if d2 != null else "-"))
	# ③ 不手动调 ⇒ headless 下不该自动挂
	var b3 := Button.new()
	b3.text = "自动?"
	vbox.add_child(b3)
	await get_tree().process_frame
	print("PROBE|③自动钩子|新按钮子节点=%d（headless 下应为 0；有窗口时应为 1）" % b3.get_child_count())
	# ④ 真·自动钩子通路：headless 下 `_ready()` 会 early-return（这是设计），所以这里**手工把钩子接上**，
	#    验证的信号名与回调本身和"有窗口时"是同一条代码路径（信号名写错的话这一行会直接报错）。
	print("PROBE|④信号存在|SceneTree.has_signal(node_added)=%s（有窗口时靠它全局生效）" % str(get_tree().has_signal("node_added")))
	UiDice._auto = true
	get_tree().node_added.connect(UiDice._on_node_added)
	var b4 := Button.new()
	b4.text = "钩子?"
	vbox.add_child(b4)
	await get_tree().process_frame
	print("PROBE|④钩子通路|接上钩子后新按钮子节点=%d（应为 1）" % b4.get_child_count())
	# ⑤ 下拉框一律不挂（OptionButton 文字左对齐 ⇒ 骰子必压字）
	var o1 := OptionButton.new()
	o1.add_item("普通")
	vbox.add_child(o1)
	UiDice.attach(o1)
	await get_tree().process_frame
	print("PROBE|⑤下拉框|手动 attach 后子节点=%d（应为 0）｜自动钩子也=%d（应为 0）" % [
		o1.get_child_count(), o1.get_child_count()])
	# ⑥ detach：删掉已挂的 + 打标记（重建/重新入树也不再长）
	UiDice.detach(b1)
	await get_tree().process_frame
	var b6 := Button.new()
	b6.text = "再入树"
	vbox.add_child(b6)
	UiDice.attach(b6)
	UiDice.detach(b6)
	UiDice.attach(b6)          # 有 no_dice 标记 ⇒ 这次不该挂
	await get_tree().process_frame
	print("PROBE|⑥detach|大按钮剩几颗=%d（应为 0）｜打标记后 attach 子节点=%d（应为 0）｜有 no_dice=%s" % [
		b1.get_child_count(), b6.get_child_count(), str(b6.has_meta("no_dice"))])
	# ⑥b 复现用户实机那条报错：detach 之后按钮再 resized / 悬浮 ⇒ 引擎会喊
	#    `Lambda capture at index 0 was freed. Passed "null" instead.`（骰子被 free 了，lambda 还连着）
	b1.size = b1.size + Vector2(1, 0)
	b1.resized.emit()
	b1.mouse_entered.emit()
	b6.size = b6.size + Vector2(1, 0)
	b6.mouse_entered.emit()
	await get_tree().process_frame
	print("PROBE|⑥b断开检查|detach 后触发 resized/悬浮完毕（控制台若出现 Lambda capture ... was freed 就是没断干净）")
	# ⑦ 宽度门控：放得下的按钮 fits=true、放不下（会压字）的按钮 fits=false
	var wide := Button.new()
	wide.text = "单机模式"
	wide.add_theme_font_size_override("font_size", 22)
	wide.custom_minimum_size = Vector2(300, 58)
	vbox.add_child(wide)
	wide.size = Vector2(300, 58)
	UiDice.attach(wide)
	var narrow := Button.new()
	narrow.text = "返回"
	narrow.add_theme_font_size_override("font_size", 22)
	narrow.custom_minimum_size = Vector2(90, 36)
	# ⚠️ 容器默认把子节点横向拉满（第一版没设 ⇒ 两颗都变成 400 宽，门控读数全 true）⇒ 显式 SHRINK
	wide.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	wide.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	narrow.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	narrow.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vbox.add_child(narrow)
	narrow.size = Vector2(90, 36)
	UiDice.attach(narrow)
	await get_tree().process_frame
	print("PROBE|⑦宽度门控|宽 300×58 fits=%s（应 true）｜窄 90×46 fits=%s（应 false）" % [
		str(UiDice._fits(wide, wide.get_node("HoverDice").size.y)),
		str(UiDice._fits(narrow, narrow.get_node("HoverDice").size.y))])
	for b: Button in [wide, narrow]:
		var f := b.get_theme_font("font")
		var fsz := b.get_theme_font_size("font_size")
		var tw := -1.0
		if f != null:
			tw = f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x
		print("PROBE|⑦诊断|%s|尺寸=%s|对齐=%d|字号=%d|文字宽=%.1f|d=%.0f|need=%.0f" % [
			b.text, str(b.size), int(b.alignment), fsz, tw,
			clampf(b.size.y - 22.0, 18.0, 36.0), 14.0 + clampf(b.size.y - 22.0, 18.0, 36.0) + 8.0])
	print("PROBE|END")
	get_tree().quit(0)

func _sha(path: String) -> String:
	var c := FileAccess.get_file_as_bytes(path)
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(c)
	return h.finish().hex_encode().substr(0, 12)
