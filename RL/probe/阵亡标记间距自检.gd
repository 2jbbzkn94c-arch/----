extends Node
## 【2026-09-30 一次性探针】顶部"阵亡标记"两排的**几何自检** —— 用户报「红方的死亡标记又贴边了、
##   和其他的间隔不一样」。要量三件事（左右两排各一遍）：
##   ① 相邻两枚的**节距**是否恒定（= `SLOT_D + MARK_GAP`）；
##   ② 最外面那枚离屏幕边的距离（左右应相同 = 12 + `MARK_EDGE_PAD`）；
##   ③ 两排的"外缘到屏边"是否一致（蓝方贴左、红方贴右 ⇒ 镜像）。
## 做法：拉起真战斗场景、等 HUD 建好，读 `_my_marks` / `_op_marks` 的全局矩形。
## 输出：每行 `MK|...`，末尾 `MK|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 6:
		await get_tree().process_frame
	var hud = _find_hud()
	if hud == null:
		print("MK|FAIL|找不到 HUD")
		get_tree().quit(1)
		return
	var vsize: Vector2 = get_viewport().get_visible_rect().size
	print("MK|视口|宽=%d 高=%d" % [int(vsize.x), int(vsize.y)])
	_report("蓝方(左)", hud._my_marks, vsize)
	_report("红方(右)", hud._op_marks, vsize)
	_dump_tree(hud, vsize)
	print("MK|END")
	get_tree().quit(0)

## 把两排标记"往上三层"的容器/名字框/标记行的全局矩形全打出来 —— 看是谁把谁挤了
func _dump_tree(hud, vsize: Vector2) -> void:
	for marks in [hud._my_marks, hud._op_marks]:
		if marks == null or marks.is_empty():
			continue
		var mk = marks[0]
		if mk == null or not is_instance_valid(mk):
			continue
		var row = mk.get_parent()
		var col = row.get_parent() if row != null else null
		_rect("标记行", row, vsize)
		_rect("  列容器(col_box)", col, vsize)
		if col != null and col is Control:
			for ch in (col as Control).get_children():
				if ch is Control and ch != row:
					_rect("  名字框", ch, vsize)
		for i in marks.size():
			var m = marks[i]
			if m != null and is_instance_valid(m):
				_rect("    标记[%d]" % i, m, vsize)

func _rect(tag: String, c, vsize: Vector2) -> void:
	if c == null or not is_instance_valid(c) or not (c is Control):
		return
	var r: Rect2 = (c as Control).get_global_rect()
	print("MK|盒子|%-28s x=%.1f..%.1f (w=%.1f)  y=%.1f..%.1f｜离左=%.1f 离右=%.1f" % [
		tag, r.position.x, r.position.x + r.size.x, r.size.x,
		r.position.y, r.position.y + r.size.y, r.position.x, vsize.x - (r.position.x + r.size.x)])

func _find_hud():
	for c in battle.get_children():
		if c != null and is_instance_valid(c) and c.get_script() != null \
				and str(c.get_script().resource_path).ends_with("HUD.gd"):
			return c
	return null

func _report(tag: String, marks: Array, vsize: Vector2) -> void:
	if marks == null or marks.is_empty():
		print("MK|%s|（没有标记）" % tag)
		return
	var xs: Array[float] = []
	var ys: Array[float] = []
	var d := 0.0
	for m in marks:
		if m == null or not is_instance_valid(m):
			continue
		var r: Rect2 = (m as Control).get_global_rect()
		xs.append(r.position.x)
		ys.append(r.position.y)
		d = r.size.x
	if xs.is_empty():
		print("MK|%s|（标记都失效了）" % tag)
		return
	var gaps: Array[String] = []
	for i in range(1, xs.size()):
		gaps.append("%.1f" % (xs[i] - xs[i - 1]))
	var left := xs[0]
	var right := vsize.x - (xs[xs.size() - 1] + d)
	print("MK|%s|枚数=%d｜边长=%.1f｜y=%.1f｜x=%s｜节距=[%s]｜离左边=%.1f｜离右边=%.1f" % [
		tag, xs.size(), d, ys[0], str(xs), "／".join(gaps), left, right])
