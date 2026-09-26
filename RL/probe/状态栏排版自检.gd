extends Node
## 【2026-09-27 一次性探针·临时】顶部状态栏排版自检 —— 用户报「**战斗中状态栏在 11 回合后，显示会挤到一起**」。
##
## 状态栏结构（`src/HUD.gd::_build()`）：一条 54px 高的全宽 PanelContainer，里面
##   ① 左：`我方` + 3 个阵亡槽（从 x=12 起排）　② 右：3 个阵亡槽 + `敌方`（贴右缘）
##   ③ 中间：`第 N 回合 · 阵营` + 火焰图标（**第 11 回合起亮**）+ 剩余时间 —— 整条**居中**
## ⇒ 回合数变两位数 / 火焰亮起 / 倒计时出现，三件事叠加会把中间那组顶到两侧。
##
## 本探针用**与 HUD 同一套字号与同一张皮肤字体**量出宽度，打印：
##   · 两侧各行实际占多宽（含阵亡槽 34px、间距 7）
##   · 中间那组在 `第 9 / 第 11 回合`（含火焰 + 倒计时）各需要多宽
##   · 中间还剩多少（视口 720 − 两侧 − 缝）⇒ **超出多少**（= 用户看到的挤）
##   · 按 `_fit_top_center()` 的档位（24 → 22 → 20 → 18）算出的应选字号
##
## 输出：每行 `SB|...`，末尾 `SB|END`。

const THEME_PATH := "res://theme/tavern_theme.tres"

func _ready() -> void:
	var vw := 720.0                     # project.godot: window/size/viewport_width = 720
	var font: Font = null
	if ResourceLoader.exists(THEME_PATH):
		var th = load(THEME_PATH)
		if th is Theme and (th as Theme).default_font != null:
			font = (th as Theme).default_font
	if font == null:
		font = ThemeDB.fallback_font
	print("SB|CFG|视口宽=%.0f|字体=%s|阵亡槽=34|槽间距=7" % [vw, ("项目主题" if font != ThemeDB.fallback_font else "引擎兜底")])
	# 两侧：名字（我方/敌方，单机 27pt）+ 3 个阵亡槽（34）+ 3 个间距（7）
	var w_name: float = font.get_string_size("我方", HORIZONTAL_ALIGNMENT_LEFT, -1, 27).x
	var side_w: float = w_name + 3.0 * 34.0 + 3.0 * 7.0
	print("SB|两侧|名字(27pt)=%.1f ⇒ 单侧合计=%.1f（左起 x=12 / 右侧贴右缘 12）" % [w_name, side_w])
	var avail: float = vw - side_w * 2.0 - 28.0
	print("SB|中间可用宽=%.1f" % avail)
	var flame_w := 34.0
	var sep := 4.0
	for case in [["第 9 回合", "第 9 回合 · 你的回合", false, false],
			["第 9 回合+倒计时", "第 9 回合 · 你的回合", false, true],
			["第 11 回合+火焰", "第 11 回合 · 你的回合", true, false],
			["第 11 回合+火焰+倒计时", "第 11 回合 · 你的回合", true, true]]:
		var label := String(case[0])
		var text := String(case[1])
		var flame := bool(case[2])
		var timer := bool(case[3])
		var tw: float = font.get_string_size("⏱ 30 秒", HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x if timer else 0.0
		var out: Array[String] = []
		for fs in [24, 22, 20, 18]:
			var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(fs)).x
			if flame:
				w += sep + flame_w
			if timer:
				w += sep + tw
			out.append("%dpt→%.0f%s" % [int(fs), w, ("✓" if w <= avail else "✗")])
		var old_w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x \
			+ (sep + flame_w if flame else 0.0) + (sep + tw if timer else 0.0)
		print("SB|%s|旧口径(恒定 24pt)需要 %.0f ⇒ %s%.0f｜各档：%s" % [label, old_w,
			("超出 " if old_w > avail else "余 "), absf(old_w - avail), " · ".join(out)])
	print("SB|END")
	get_tree().quit(0)
