extends Node
## 临时探针:无渲染器直接光栅化棋盘到 PNG(纯 Image 写像素),目视顶帽/出生区形状。
var dir := "D:/Game creating/战旗/.cap_probe_out"
func fill_hex(img: Image, cx: float, cy: float, r: float, col: Color) -> void:
	for dy in range(int(-r) - 1, int(r) + 2):
		var y := cy + dy
		if y < 0 or y >= img.get_height():
			continue
		for dx in range(int(-r) - 1, int(r) + 2):
			var x := cx + dx
			if x < 0 or x >= img.get_width():
				continue
			if Vector2(dx, dy).length() <= r:
				img.set_pixel(int(x), int(y), col)
func render_png(g: HexGrid, zone: Array, fname: String, title: String) -> void:
	var cells := g.all_cells()
	var minx := 1 << 30
	var miny := 1 << 30
	var maxx := -(1 << 30)
	var maxy := -(1 << 30)
	for c in cells:
		var p := g.cell_to_world(c)
		minx = mini(minx, int(p.x - g.hex_size))
		miny = mini(miny, int(p.y - g.hex_size))
		maxx = maxi(maxx, int(p.x + g.hex_size))
		maxy = maxi(maxy, int(p.y + g.hex_size))
	var pad := 60
	var W := maxx - minx + pad * 2
	var H := maxy - miny + pad * 2
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.13, 0.15, 0.2, 1.0))
	var ox := pad - minx
	var oy := pad - miny
	for c in cells:
		var p := g.cell_to_world(c)
		var col := Color(0.5, 0.55, 0.65, 1.0)
		if c.y == g.height - 1:
			col = Color(0.25, 0.45, 0.8, 1.0)
		if zone.has(c):
			col = Color(0.85, 0.3, 0.3, 1.0)
		fill_hex(img, ox + p.x, oy + p.y, g.hex_size * 0.92, col)
		img.set_pixel(ox + int(p.x), oy + int(p.y), Color.WHITE)
	img.save_png("%s/%s" % [dir, fname])
	print("saved %s  %dx%d" % [fname, W, H])

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	print("=== 旧7列 7x7 top_cap[1,3,5] ===")
	var g1 := HexGrid.new(7, 7, 48.0)
	g1.top_cap_cols = [1, 3, 5]
	var z1: Array = [Vector2i(0, 1), Vector2i(1, 0), Vector2i(2, 1), Vector2i(3, 0), Vector2i(4, 1), Vector2i(5, 0), Vector2i(6, 1)]
	render_png(g1, z1, "old7.png", "old7")
	print("=== 现5列 top_cap[0,2,4] ===")
	var g2 := HexGrid.new(5, 7, 48.0)
	g2.top_cap_cols = [0, 2, 4]
	var z2: Array = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 0), Vector2i(3, 1), Vector2i(4, 0)]
	render_png(g2, z2, "new5.png", "new5")
	get_tree().quit()
