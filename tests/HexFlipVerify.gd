extends Node
## 校验联机访客视角翻转的渲染几何：
## 1) 翻转是精确的 180° 点反射：每个格子的翻转像素 = center*2 - 原始像素；
## 2) 我方阵营(ENEMY)翻转后屏幕 y 更大（更靠下），即"自己的英雄在下方"；
## 3) cell_to_world 与 world_to_cell 往返一致（翻/不翻都精确）；
## 4) cell_to_world 的 bbox 在翻/不翻下一致（棋盘仍居中，不漂移）。
## 运行：godot --headless --scene res://tests/HexFlipVerify.tscn
var grid: HexGrid

func _ready() -> void:
	grid = HexGrid.new(7, 9, 48.0)
	grid.top_cap_cols = [1, 3, 5]
	_run.call_deferred()

func bbox(g: HexGrid) -> Dictionary:
	var minx := INF; var miny := INF; var maxx := -INF; var maxy := -INF
	for c in g.all_cells():
		var p := g.cell_to_world(c)
		minx = min(minx, p.x); miny = min(miny, p.y)
		maxx = max(maxx, p.x); maxy = max(maxy, p.y)
	return { "minx": minx, "miny": miny, "maxx": maxx, "maxy": maxy }

func _run() -> void:
	# --- 不反转基准 bbox ---
	var b0 := bbox(grid)
	# --- 开翻转：枚举每个格子验证反射关系 & 往返 ---
	grid.view_flip = true
	var ok := true
	# 中心 = 不反转像素坐标的 包围盒 中心
	var cy := (float(b0.miny) + float(b0.maxy)) / 2.0
	var cx := (float(b0.minx) + float(b0.maxx)) / 2.0
	# 3') 翻转是等距(isometry)：任意两格翻转后的像素距离 = 原始像素距离（无畸变）
	var cells := grid.all_cells()
	for i in cells.size():
		for j in cells.size():
			var a := cells[i]; var b := cells[j]
			var da := (grid._raw_cell_to_world(a) - grid._raw_cell_to_world(b)).length()
			var db := (grid.cell_to_world(a) - grid.cell_to_world(b)).length()
			if abs(da - db) > 0.001:
				ok = false
				print("  等距失真 %s,%s: %f vs %f" % [str(a), str(b), da, db])
	for c in grid.all_cells():
		var raw := grid._raw_cell_to_world(c)
		var flipped := grid.cell_to_world(c)
		# 1) 反射关系
		var expect := Vector2(cx * 2.0 - raw.x, cy * 2.0 - raw.y)
		if flipped.distance_to(expect) > 0.001:
			ok = false
			print("  反射不符 %s: %s vs %s" % [str(c), str(flipped), str(expect)])
		# 3) 往返
		var back := grid.world_to_cell(flipped)
		if back != c:
			ok = false
			print("  往返不符 %s -> %s" % [str(c), str(back)])
	# 2) 我方阵营(ENEMY 顶部 row0/1)翻转后应在屏幕下方
	var top_cell := Vector2i(1, 0)   # 顶帽
	var top_flipped_y := grid.cell_to_world(top_cell).y
	var top_raw_y := grid._raw_cell_to_world(top_cell).y
	if top_flipped_y <= top_raw_y:
		ok = false
		print("  顶部格未翻转到下方: flipped_y=%f raw_y=%f" % [top_flipped_y, top_raw_y])
	# 4) 翻转不改变"哪一侧是最底行"：原底部(我方PLAYER row=height-1)翻转后应到最上方
	print("T1 访客视角翻转: 顶部格翻转后靠下=%s 无畸变+反射+往返=%s => %s" % [
		str(top_flipped_y > top_raw_y), str(ok), "PASS" if ok and top_flipped_y > top_raw_y else "FAIL"])
	get_tree().quit()
