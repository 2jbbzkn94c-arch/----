extends SceneTree
## 工具：清掉名字框素材**右下角**的 AI 生成水印（豆包出图自带的那种浅色小字，压在缎带底色上）。
##
## 为什么需要：`蓝方名字框.png` / `红方名字框.png` 是 AI 生成的，右下角带一排浅色小字水印；
##   在游戏里名字框被拉成 223×42 显示，那排字仍然看得见（用户报："怎么蓝色的背景有AI水印"）。
##
## 判据（三步，都在右下角这一块里做，其余像素一个不动）：
##   ① **底色线**：按行用"宽窗低分位亮度"（默认 25 分位、半窗 12% 图宽、粗格 3% 图宽）
##      —— 低分位对"密集笔画把邻域均值抬高"不敏感，所以字再多也压不弯它。
##   ② **水印像素**：亮度比底色线高 ≥ `WM_DEV`，且**不是中性高光**（缎带两端的白描边是 r≈g≈b 的亮色，
##      水印是带蓝味的浅色 ⇒ 用"最大通道−最小通道 ≤ 0.12"把描边排除，别把缎带边线擦掉）。
##   ③ **丢小块**：连通域面积小于 `min_area` 的当素材自带的细纹理噪点，不碰（面积阈值按图宽缩放）。
##      最后把判定为水印的像素，用该像素左右**干净像素**的横向窗口均值回填
##      —— 底色和底部那条高光带都是横向一致的 ⇒ 回填天然接得上，不会留补丁边；反复几遍直到收敛。
##
## 用法：
##   godot --headless --path <项目> --script res://tools/清名字框水印.gd              # 只出预览，不动 assets
##   godot --headless --path <项目> --script res://tools/清名字框水印.gd -- --apply   # 覆盖 assets（原图先备份到 log/）
## 预览图写到 `.dsh/tmp/净_<原名>.png`，备份写到 `log/<bak>`，报告写到 `.dsh/tmp/清名字框水印_report.txt`。

const JOBS := [
	{"src": "res://assets/界面/蓝方名字框.png", "bak": "名字框_原图备份_蓝方_带水印.png"},
	{"src": "res://assets/界面/红方名字框.png", "bak": "名字框_原图备份_红方_带水印.png"},
]
const PREVIEW_DIR := "res://.dsh/tmp"
const BACKUP_DIR := "res://log"
const REPORT := "res://.dsh/tmp/清名字框水印_report.txt"

## 只在右下角这一块里找水印（占图比例）
const WM_X0 := 0.55
const WM_X1 := 0.98
const WM_Y0 := 0.45
const WM_Y1 := 0.99
const WM_WIN := 0.12        # 底色线：横向半窗
const WM_CELL := 0.03       # 底色线：粗格宽（格间线性过渡）
const WM_DEV := 0.05        # 比底色线亮这么多 ⇒ 算水印笔画
const WM_PASSES := 6

var _fp: FileAccess = null

func _initialize() -> void:
	_run.call_deferred()

func _say(s: String) -> void:
	print(s)
	if _fp == null:
		_fp = FileAccess.open(REPORT, FileAccess.WRITE)
	if _fp != null:
		_fp.store_line(s)
		_fp.flush()

func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

## 中性高光（缎带两端的白描边）：亮 & 三通道几乎相等 ⇒ 水印是带蓝味的浅色，能被这条排除掉
func _neutral_bright(c: Color) -> bool:
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	return c.a > 0.5 and mx > 0.60 and mx - mn <= 0.12

## 把面积过小的连通域从掩码里去掉（那是素材自带的纹理噪点/抗锯齿点，不是水印笔画）
func _drop_small(mask: PackedByteArray, mw: int, mh: int, min_area: int) -> int:
	var seen := PackedByteArray()
	seen.resize(mw * mh)
	var killed := 0
	for i in mw * mh:
		if mask[i] == 0 or seen[i] == 1:
			continue
		var stack := PackedInt32Array([i])
		var comp := PackedInt32Array([i])
		seen[i] = 1
		while stack.size() > 0:
			var cur: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			var cx := cur % mw
			var cy := cur / mw
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx := cx + dx
					var ny := cy + dy
					if nx < 0 or ny < 0 or nx >= mw or ny >= mh:
						continue
					var ni := ny * mw + nx
					if mask[ni] == 1 and seen[ni] == 0:
						seen[ni] = 1
						stack.append(ni)
						comp.append(ni)
		if comp.size() < min_area:
			for ci in comp.size():
				mask[comp[ci]] = 0
				killed += 1
	return killed

func _clean(img: Image) -> int:
	var w := img.get_width()
	var h := img.get_height()
	var xa := int(float(w) * WM_X0)
	var xb := int(float(w) * WM_X1)
	var ya := int(float(h) * WM_Y0)
	var yb := int(float(h) * WM_Y1)
	var win := maxi(8, int(float(w) * WM_WIN))
	var cell := maxi(4, int(float(w) * WM_CELL))
	var samp := maxi(1, int(float(w) / 512.0))
	var ncell := int(ceil(float(xb - xa) / float(cell))) + 1
	var min_area := maxi(6, int(6.0 * pow(float(w) / 384.0, 1.4)))
	var mw := xb - xa
	var mh := yb - ya
	var total := 0
	for pi in WM_PASSES:
		# ---- ① 掩码：比"底色线"亮、且不是缎带描边 ----
		var mask := PackedByteArray()
		mask.resize(mw * mh)
		for y in range(ya, yb):
			var base := PackedFloat32Array()
			base.resize(ncell)
			for ci in ncell:
				var xc := xa + ci * cell
				var l := maxi(0, xc - win)
				var r := mini(w - 1, xc + win)
				var vals := PackedFloat32Array()
				var x := l
				while x <= r:
					vals.append(_lum(img.get_pixel(x, y)))
					x += samp
				vals.sort()
				base[ci] = vals[clampi(int(float(vals.size()) * 0.25), 0, vals.size() - 1)]
			for x in range(xa, xb):
				var off := x - xa
				var ci2 := off / cell
				var t := float(off % cell) / float(cell)
				var bx: float = lerpf(base[ci2], base[mini(ci2 + 1, ncell - 1)], t)
				var c := img.get_pixel(x, y)
				if _lum(c) - bx >= WM_DEV and not _neutral_bright(c):
					mask[(y - ya) * mw + off] = 1
		var killed := _drop_small(mask, mw, mh, min_area)
		var n := 0
		for i in mw * mh:
			if mask[i] == 1:
				n += 1
		if n == 0:
			_say("  第 %d 遍：掩码空（丢小块 %d）⇒ 收敛" % [pi + 1, killed])
			break
		# ---- ② 回填：用左右"干净像素"的横向窗口均值（脏像素和缎带描边都不参与平均）----
		var changed := 0
		var x_s := maxi(0, xa - win)
		var x_e := mini(w - 1, xb + win)
		var n2 := x_e - x_s + 1
		for y in range(ya, yb):
			var sr := PackedFloat32Array(); var sg := PackedFloat32Array(); var sb := PackedFloat32Array()
			var sc := PackedInt32Array()
			sr.resize(n2 + 1); sg.resize(n2 + 1); sb.resize(n2 + 1); sc.resize(n2 + 1)
			sr[0] = 0.0; sg[0] = 0.0; sb[0] = 0.0; sc[0] = 0
			for i in n2:
				var x := x_s + i
				var c := img.get_pixel(x, y)
				var skip := _neutral_bright(c)
				if not skip and x >= xa and x < xb and mask[(y - ya) * mw + (x - xa)] == 1:
					skip = true
				if skip:
					sr[i + 1] = sr[i]; sg[i + 1] = sg[i]; sb[i + 1] = sb[i]; sc[i + 1] = sc[i]
				else:
					sr[i + 1] = sr[i] + c.r; sg[i + 1] = sg[i] + c.g; sb[i + 1] = sb[i] + c.b
					sc[i + 1] = sc[i] + 1
			var todo: Array = []
			for x in range(xa, xb):
				if mask[(y - ya) * mw + (x - xa)] == 0:
					continue
				var i0 := clampi(x - win - x_s, 0, n2 - 1)
				var i1 := clampi(x + win - x_s, 0, n2 - 1)
				var cnt := sc[i1 + 1] - sc[i0]
				if cnt <= 0:
					continue
				var fc := float(cnt)
				todo.append([x, Color((sr[i1 + 1] - sr[i0]) / fc, (sg[i1 + 1] - sg[i0]) / fc,
					(sb[i1 + 1] - sb[i0]) / fc, img.get_pixel(x, y).a)])
			for it in todo:
				img.set_pixel(int(it[0]), y, it[1])
				changed += 1
		_say("  第 %d 遍：掩码 %d 个（丢小块 %d）⇒ 改写 %d 个像素" % [pi + 1, n, killed, changed])
		total += changed
		if changed == 0:
			break
	return total

## ---- 验收读数（和干净对照块比，确认没有残留"字"形结构）----
func _hot_rect(img: Image, x0: int, x1: int, y0: int, y1: int) -> int:
	var w := img.get_width()
	var win := maxi(6, int(float(w) * 0.055))
	var n := 0
	for y in range(y0, y1):
		var pre := PackedFloat32Array(); pre.resize(w + 1); pre[0] = 0.0
		for x in w:
			pre[x + 1] = pre[x] + _lum(img.get_pixel(x, y))
		for x in range(x0, x1):
			var l := maxi(0, x - win); var r := mini(w - 1, x + win)
			var bb := (pre[r + 1] - pre[l]) / float(r - l + 1)
			if _lum(img.get_pixel(x, y)) - bb >= 0.06:
				n += 1
	return n

func _tex(img: Image, x0: int, x1: int, y0: int, y1: int) -> float:
	var w := img.get_width()
	var win := maxi(6, int(float(w) * 0.055))
	var s := 0.0
	var n := 0
	for y in range(y0, y1):
		var pre := PackedFloat32Array(); pre.resize(w + 1); pre[0] = 0.0
		for x in w:
			pre[x + 1] = pre[x] + _lum(img.get_pixel(x, y))
		for x in range(x0, x1):
			var l := maxi(0, x - win); var r := mini(w - 1, x + win)
			var bb := (pre[r + 1] - pre[l]) / float(r - l + 1)
			s += absf(_lum(img.get_pixel(x, y)) - bb)
			n += 1
	return s / float(maxi(1, n))

func _max_comp(img: Image, x0: int, x1: int, y0: int, y1: int) -> int:
	var w := img.get_width()
	var win := maxi(6, int(float(w) * 0.055))
	var mw := x1 - x0
	var mh := y1 - y0
	var mask := PackedByteArray()
	mask.resize(mw * mh)
	for y in range(y0, y1):
		var pre := PackedFloat32Array(); pre.resize(w + 1); pre[0] = 0.0
		for x in w:
			pre[x + 1] = pre[x] + _lum(img.get_pixel(x, y))
		for x in range(x0, x1):
			var l := maxi(0, x - win); var r := mini(w - 1, x + win)
			var bb := (pre[r + 1] - pre[l]) / float(r - l + 1)
			if _lum(img.get_pixel(x, y)) - bb >= 0.06:
				mask[(y - y0) * mw + (x - x0)] = 1
	var seen := PackedByteArray()
	seen.resize(mw * mh)
	var best := 0
	for i in mw * mh:
		if mask[i] == 0 or seen[i] == 1:
			continue
		var stack := PackedInt32Array([i])
		seen[i] = 1
		var n := 0
		while stack.size() > 0:
			var cur: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			var cx := cur % mw
			var cy := cur / mw
			n += 1
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx := cx + dx
					var ny := cy + dy
					if nx < 0 or ny < 0 or nx >= mw or ny >= mh:
						continue
					var ni := ny * mw + nx
					if mask[ni] == 1 and seen[ni] == 0:
						seen[ni] = 1
						stack.append(ni)
		best = maxi(best, n)
	return best

func _run() -> void:
	var apply := OS.get_cmdline_user_args().has("--apply")
	_say("==== 清名字框水印 ｜ %s ====" % ("覆盖 assets（先备份）" if apply else "预览模式（不动 assets）"))
	for job in JOBS:
		var src: String = job["src"]
		var tex := load(src) as Texture2D
		if tex == null:
			_say("!! 载入失败 " + src)
			continue
		var img := tex.get_image()
		img.convert(Image.FORMAT_RGBA8)
		var w := img.get_width()
		var h := img.get_height()
		var bx0 := int(float(w) * 0.70); var bx1 := int(float(w) * 0.975)
		var by0 := int(float(h) * 0.56); var by1 := int(float(h) * 0.92)
		var cx0 := int(float(w) * 0.40); var cx1 := cx0 + (bx1 - bx0)
		_say("---- %s  %d×%d ----" % [src.get_file(), w, h])
		_say("  前：水印块亮点 %d（最大连通域 %d）｜纹理能量 %.4f" % [
			_hot_rect(img, bx0, bx1, by0, by1), _max_comp(img, bx0, bx1, by0, by1), _tex(img, bx0, bx1, by0, by1)])
		var t0 := Time.get_ticks_msec()
		var n := _clean(img)
		_say("  共改写 %d 像素，耗时 %d ms" % [n, Time.get_ticks_msec() - t0])
		_say("  后：水印块亮点 %d（最大连通域 %d）｜纹理能量 %.4f" % [
			_hot_rect(img, bx0, bx1, by0, by1), _max_comp(img, bx0, bx1, by0, by1), _tex(img, bx0, bx1, by0, by1)])
		_say("  对照块（同尺寸、干净）：亮点 %d（最大连通域 %d）｜纹理能量 %.4f" % [
			_hot_rect(img, cx0, cx1, by0, by1), _max_comp(img, cx0, cx1, by0, by1), _tex(img, cx0, cx1, by0, by1)])
		var out_path := src
		if not apply:
			out_path = "%s/净_%s" % [PREVIEW_DIR, src.get_file()]
		else:
			var bak := "%s/%s" % [BACKUP_DIR, String(job["bak"])]
			var src_abs := ProjectSettings.globalize_path(src)
			var bak_abs := ProjectSettings.globalize_path(bak)
			var raw := FileAccess.open(src_abs, FileAccess.READ)
			if raw != null:
				var bytes := raw.get_buffer(raw.get_length())
				raw.close()
				var bw := FileAccess.open(bak_abs, FileAccess.WRITE)
				if bw != null:
					bw.store_buffer(bytes)
					bw.close()
					_say("  原图备份 → %s" % bak)
				else:
					_say("  !! 备份写不进去：%s" % bak)
					continue
			else:
				_say("  !! 读不到源文件：%s" % src_abs)
				continue
		var err := img.save_png(ProjectSettings.globalize_path(out_path))
		_say("  写出 %s err=%d" % [out_path, err])
	_say("== 结束 ==")
	quit(0)
