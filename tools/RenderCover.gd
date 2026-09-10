extends Node
## 封面/背景渲染工具：把 assets/美术资源/背景/ 下的每个 SVG 源文件栅格化成同名 PNG 贴图。
## 走 Godot 内置 ThorVG（CPU 渲染），无需外部转换器，headless 可用。
## 运行：godot --headless --scene res://tools/RenderCover.tscn
## 出图后需让 Godot 重新导入贴图：godot --headless --import
##
## 注意（ThorVG 限制）：不支持 <text> 文字与滤镜（feGaussianBlur 等）——光晕请用径向渐变做。
const DIR := "res://assets/美术资源/背景/"
const SCALE := 2.0   # 2x：720x1280 设计尺寸 -> 1440x2560 贴图，高 DPI 铺满不糊

func _ready() -> void:
	var dir := DirAccess.open(DIR)
	if dir == null:
		push_error("打不开目录：%s" % DIR)
		get_tree().quit(1)
		return
	var n := 0
	var bad := 0
	for f in dir.get_files():
		if not f.to_lower().ends_with(".svg"):
			continue
		var src := DIR + f
		var out := DIR + f.substr(0, f.length() - 4) + ".png"
		var txt := FileAccess.get_file_as_string(src)
		if txt.is_empty():
			push_error("读不到 SVG：%s" % src)
			bad += 1
			continue
		var img := Image.new()
		var err := img.load_svg_from_string(txt, SCALE)
		if err != OK:
			push_error("SVG 栅格化失败（err=%d）：%s" % [err, src])
			bad += 1
			continue
		var err2 := img.save_png(out)
		if err2 != OK:
			push_error("写 PNG 失败（err=%d）：%s" % [err2, out])
			bad += 1
			continue
		print(">> %s  ->  %s  (%d x %d)" % [f, out.get_file(), img.get_width(), img.get_height()])
		n += 1
	print(">> 完成：%d 张成功，%d 张失败" % [n, bad])
	get_tree().quit(0 if bad == 0 and n > 0 else 1)
