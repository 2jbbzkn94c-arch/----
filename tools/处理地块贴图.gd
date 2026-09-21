extends SceneTree
## 临时工具：把用户提供的图片处理成棋盘能用的贴图（去底色 / 裁边 / 必要时旋转）。
## 现在支持两种：
##   kind=hex_rotate —— 地块木纹：去奶白底 + 六边形遮罩裁掉四角水印 + 裁到图案边界 + 旋转 90°
##                      （用户给的是"顶点朝上"的六边形，棋盘是"平边朝上"，必须转过来）
##   kind=plain      —— 障碍等其他素材：去白底（按"与底色差得远"的像素取内容框，浅浅的水印会被排除）
##                      + 裁到内容框 + 缩到不超过 max_w
## 用法：godot --headless --path <项目> --script res://tools/处理地块贴图.gd
## 源图放在 log/ 下（该目录被 gitignore，不污染仓库）。

const JOBS := [
	{
		"kind": "hex_rotate",
		"src": "D:/Game creating/战旗/log/_tile_src1.jpg",
		"out": "res://assets/美术资源/地块木板1.png",
	},
	{
		"kind": "hex_rotate",
		"src": "D:/Game creating/战旗/log/_tile_src2.jpg",
		"out": "res://assets/美术资源/地块木板2.png",
	},
	{
		"kind": "plain",
		"src": "D:/Game creating/战旗/log/_obstacle_src.png",
		"out": "res://assets/美术资源/障碍.png",
		"max_w": 512,
		"stroke": 12,   # 黑色描边（成品像素；512 宽缩到屏幕约 100px 时≈2.3px）
		"stroke_color": Color(0, 0, 0, 1),
	},
	{
		"kind": "plain",
		"src": "D:/Game creating/战旗/log/_shield_src.jpg",
		"out": "res://assets/美术资源/圣盾.png",
		"max_w": 512,
	},
	{
		"kind": "plain",
		"src": "D:/Game creating/战旗/assets/美术资源/攻击.png",
		"out": "res://assets/美术资源/道具攻击.png",
		"max_w": 384,
	},
	{
		"kind": "plain",
		"src": "D:/Game creating/战旗/assets/美术资源/爱心.png",
		"out": "res://assets/美术资源/道具爱心.png",
		"max_w": 384,
	},
	{
		"kind": "plain",
		"src": "D:/Game creating/战旗/log/_move_wings_src.png",
		"out": "res://assets/美术资源/道具移动.png",
		"max_w": 512,
	},
]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for job in JOBS:
		if String(job["kind"]) == "hex_rotate":
			_make_hex_tile(String(job["src"]), String(job["out"]))
		else:
			_make_plain(String(job["src"]), String(job["out"]), int(job.get("max_w", 512)),
				int(job.get("stroke", 0)), job.get("stroke_color", Color(0, 0, 0, 1)))
	quit(0)

# 沿不透明区域向外"长"出 thickness 像素的黑描边（迭代 4 邻域膨胀，够快也够圆润）
func _add_stroke(img: Image, thickness: int, col: Color) -> void:
	if thickness <= 0:
		return
	var w := img.get_width()
	var h := img.get_height()
	var solid := PackedByteArray()
	solid.resize(w * h)
	for y in h:
		for x in w:
			solid[y * w + x] = 1 if img.get_pixel(x, y).a > 0.5 else 0
	var grow := solid.duplicate()
	for _i in thickness:
		var next := grow.duplicate()
		for y in h:
			for x in w:
				var idx := y * w + x
				if grow[idx] == 1:
					continue
				if (x > 0 and grow[idx - 1] == 1) or (x < w - 1 and grow[idx + 1] == 1) \
						or (y > 0 and grow[idx - w] == 1) or (y < h - 1 and grow[idx + w] == 1):
					next[idx] = 1
		grow = next
	for y in h:
		for x in w:
			var idx := y * w + x
			if grow[idx] == 1 and solid[idx] == 0:
				img.set_pixel(x, y, col)

# ---- 通用：按"与左上角底色的差异"找内容框。strict 越大越严格（浅浅的水印就会被排除）----
func _content_bbox(img: Image, bg: Color, strict: float) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	var min_x := w
	var max_x := -1
	var min_y := h
	var max_y := -1
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue   # 已抠成透明的像素不算内容（抠图只改 alpha，RGB 仍是原底色）
			var d: float = (absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b)) / 3.0
			if d > strict:
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
				min_y = mini(min_y, y)
				max_y = maxi(max_y, y)
	if max_x < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)

# 从四边"灌水"式抠底：只有与边框相连的底色区域才透明，
# 图案内部的白色/高光（如盾面金属反光）会被保留，不会被挖成洞。
func _flood_remove_bg(img: Image, bg: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var n := w * h
	var is_bgf := PackedByteArray()
	is_bgf.resize(n)
	var stack := PackedInt32Array()
	# 四边上的底色像素作为种子
	for x in w:
		for k in 2:
			var y := 0 if k == 0 else h - 1
			if _is_bg(img.get_pixel(x, y), bg):
				var idx := y * w + x
				if is_bgf[idx] == 0:
					is_bgf[idx] = 1
					stack.append(idx)
	for y in h:
		for k in 2:
			var x := 0 if k == 0 else w - 1
			if _is_bg(img.get_pixel(x, y), bg):
				var idx2 := y * w + x
				if is_bgf[idx2] == 0:
					is_bgf[idx2] = 1
					stack.append(idx2)
	while stack.size() > 0:
		var idx := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		var px := idx % w
		var py := idx / w
		if px > 0:
			var a := idx - 1
			if is_bgf[a] == 0 and _is_bg(img.get_pixel(px - 1, py), bg):
				is_bgf[a] = 1
				stack.append(a)
		if px < w - 1:
			var b := idx + 1
			if is_bgf[b] == 0 and _is_bg(img.get_pixel(px + 1, py), bg):
				is_bgf[b] = 1
				stack.append(b)
		if py > 0:
			var c := idx - w
			if is_bgf[c] == 0 and _is_bg(img.get_pixel(px, py - 1), bg):
				is_bgf[c] = 1
				stack.append(c)
		if py < h - 1:
			var d := idx + w
			if is_bgf[d] == 0 and _is_bg(img.get_pixel(px, py + 1), bg):
				is_bgf[d] = 1
				stack.append(d)
	# 灌到的区域全透明；紧贴它的"半底色"像素给一段 alpha 过渡，避免锯齿硬边
	for y in h:
		for x in w:
			var i3 := y * w + x
			var col := img.get_pixel(x, y)
			if is_bgf[i3] == 1:
				col.a = 0.0
				img.set_pixel(x, y, col)
				continue
			var on_edge := false
			if x > 0 and is_bgf[i3 - 1] == 1:
				on_edge = true
			elif x < w - 1 and is_bgf[i3 + 1] == 1:
				on_edge = true
			elif y > 0 and is_bgf[i3 - w] == 1:
				on_edge = true
			elif y < h - 1 and is_bgf[i3 + w] == 1:
				on_edge = true
			if on_edge:
				var dd: float = (absf(col.r - bg.r) + absf(col.g - bg.g) + absf(col.b - bg.b)) / 3.0
				if dd < 0.30:
					col.a = clampf(dd / 0.30, 0.0, 1.0)
					img.set_pixel(x, y, col)

func _is_bg(c: Color, bg: Color) -> bool:
	var d: float = (absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b)) / 3.0
	return d < 0.06

# ---- 普通素材：去白底 + 裁到内容框 + 缩放 ----
func _make_plain(src: String, out: String, max_w: int, stroke: int = 0, stroke_color: Variant = null) -> void:
	var img := Image.load_from_file(src)
	if img == null:
		print("!! 读不到 ", src)
		return
	img.convert(Image.FORMAT_RGBA8)
	var bg := img.get_pixel(1, 1)
	# 内容框用严格阈值（0.35）：把底部浅浅的"AI生成"水印排除在外
	var box := _content_bbox(img, bg, 0.35)
	if box.size.x <= 0:
		print("!! 没找到内容 ", src)
		return
	img = img.get_region(box)
	if max_w > 0 and img.get_width() > max_w:
		var nh := int(round(float(img.get_height()) * float(max_w) / float(img.get_width())))
		img.resize(max_w, nh, Image.INTERPOLATE_LANCZOS)
	# 先裁边+缩放，再做"从边框灌水"式抠底（在成品尺寸上跑，快；也避免把图案内部的白色高光挖成洞）
	_flood_remove_bg(img, bg)
	# 描边放在缩放到成品尺寸之后做，这样 thickness 就是"成品像素"，好按屏幕观感调。
	# 注意：裁到内容框后图的四边就是图案本体，没有余量——必须先垫一圈透明边，否则描边会被裁掉。
	var scol: Color = stroke_color if stroke_color is Color else Color(0, 0, 0, 1)
	if stroke > 0:
		var pw := img.get_width() + stroke * 2
		var ph := img.get_height() + stroke * 2
		var pad := Image.create_empty(pw, ph, false, Image.FORMAT_RGBA8)
		pad.fill(Color(0, 0, 0, 0))
		pad.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(stroke, stroke))
		img = pad
	_add_stroke(img, stroke, scol)
	var err := img.save_png(out)
	print("  内容框 %s → %dx%d  描边 %dpx  err=%d → %s" % [box, img.get_width(), img.get_height(), stroke, err, out])

# ---- 地块木纹：去底色 + 六边形遮罩 + 裁边 + 旋转 90° ----
func _make_hex_tile(src: String, out: String) -> void:
	var img := Image.load_from_file(src)
	if img == null:
		print("!! 读不到 ", src)
		return
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()

	# ① 找六边形本体：逐行取最长的一段连续"非底色"像素（角落水印是零碎小段，会被排除）
	var bg := img.get_pixel(2, 2)
	var top := -1
	var bottom := -1
	var widest := 0
	var cx := float(w) * 0.5
	for y in h:
		var run_start := -1
		var best_x0 := -1
		var best_x1 := -1
		var best_len := 0
		for x in w:
			var c := img.get_pixel(x, y)
			var d: float = absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b)
			if d > 0.22:
				if run_start < 0:
					run_start = x
				var ln := x - run_start + 1
				if ln > best_len:
					best_len = ln
					best_x0 = run_start
					best_x1 = x
			else:
				run_start = -1
		if best_len >= 8:
			if top < 0:
				top = y
			bottom = y
			if best_len > widest:
				widest = best_len
				cx = float(best_x0 + best_x1) * 0.5
	if top < 0:
		print("!! 没找到六边形 ", src)
		return
	var cy := float(top + bottom) * 0.5
	# 原图是"顶点朝上"的正六边形：半宽 = √3/2 × 半高 → 用最宽处反推理想半高
	var hw := float(widest) * 0.5 + 2.0
	var hh := hw * 2.0 / sqrt(3.0)

	# ② 底色透明 + ③ 六边形遮罩
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var dx: float = absf(float(x) - cx)
			var dy: float = absf(float(y) - cy)
			var inside := dx <= hw and dy <= hh and (dx / (sqrt(3.0) * hh) + dy / hh) <= 1.0
			if not inside:
				c.a = 0.0
			else:
				var d: float = absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b)
				if d < 0.10:
					c.a = 0.0
				elif d < 0.25:
					c.a = (d - 0.10) / 0.15
				else:
					c.a = 1.0
			img.set_pixel(x, y, c)

	# ④ 裁到实际内容外框（遮罩是理想正六边形，比原图略高，不裁上下会留透明边）
	var box := _content_bbox(img, Color(0, 0, 0, 0), 0.5)
	if box.size.x <= 0:
		print("!! 遮罩后没有内容 ", src)
		return
	var cropped := img.get_region(box)
	cropped.rotate_90(0)   # 0 = 顺时针
	var err := cropped.save_png(out)
	print("  内容框 %s → 旋转后 %dx%d  err=%d → %s" % [box, cropped.get_width(), cropped.get_height(), err, out])
