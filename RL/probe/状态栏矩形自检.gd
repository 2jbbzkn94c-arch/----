extends Node
## 【2026-09-29 一次性探针】顶部状态栏**实测矩形** —— 用户报「回合数还是没贴边、计时器一出现就上下跳」。
## 打印：整条顶栏（PanelContainer）· 它的样式内边距 · 中间那组（VBox）· 回合数那一行 · 回合数 Label ·
##   计时器 Label · 两条名字框 —— 全部 `get_global_rect()` 实测值（不是推算）。
## 输出：每行 `TB|...`，末尾 `TB|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	GameState.player_deck = ["hero_06", "hero_13", "hero_12"]
	GameState.enemy_deck = ["hero_10", "hero_11", "hero_14"]
	GameState.pick_deck_in_battle = false
	battle._first_side_decided = true
	battle._deploy_side = 0
	battle._begin_deployment()
	for i in 6:
		await get_tree().process_frame
	var hud = battle._hud
	hud._refresh_deaths()
	await get_tree().process_frame
	print("TB|view=%s" % str(get_viewport().get_visible_rect().size))
	var rl: Control = hud._round_label
	print("TB|round=%s|text=%s|fs=%d" % [str(rl.get_global_rect()), rl.text, rl.get_theme_font_size("font_size")])
	print("TB|timer=%s|vis=%s" % [str(hud._turn_timer_label.get_global_rect()), str(hud._turn_timer_label.visible)])
	var row_a: Control = rl.get_parent()
	print("TB|rowA=%s|vflags=%d" % [str(row_a.get_global_rect()), row_a.size_flags_vertical])
	var toph: Control = row_a.get_parent()
	print("TB|toph=%s|type=%s|align=%d" % [str(toph.get_global_rect()), toph.get_class(), (toph as VBoxContainer).alignment])
	var pan: Control = toph.get_parent()
	print("TB|panel=%s|min=%s|type=%s" % [str(pan.get_global_rect()), str(pan.get_combined_minimum_size()), pan.get_class()])
	var sb: StyleBox = (pan as PanelContainer).get_theme_stylebox("panel")
	print("TB|panel_sb=%s|cm=%.1f/%.1f/%.1f/%.1f|tm=%s" % [sb.get_class(),
		sb.content_margin_top, sb.content_margin_bottom, sb.content_margin_left, sb.content_margin_right,
		str(sb.get("texture_margin_top"))])
	if hud._top_stack_blue != null:
		print("TB|plate_blue=%s" % str(hud._top_stack_blue.get_global_rect()))
	if hud._top_stack_red != null:
		print("TB|plate_red=%s" % str(hud._top_stack_red.get_global_rect()))
	if hud._my_death_name != null:
		print("TB|name_my=%s|text=%s" % [str(hud._my_death_name.get_global_rect()), hud._my_death_name.text])
	# ② 把计时器显出来，再看回合数有没有挪位（用户报的"上上下下"）
	var y_no_timer: float = rl.get_global_rect().position.y
	hud._turn_timer_label.text = "⏱ 30 秒"
	hud._turn_timer_label.visible = true
	hud._fit_top_center()
	for i in 3:
		await get_tree().process_frame
	var y_timer: float = rl.get_global_rect().position.y
	print("TB|带计时器|round=%s|fs=%d|y差=%.1f" % [str(rl.get_global_rect()),
		rl.get_theme_font_size("font_size"), y_timer - y_no_timer])
	print("TB|带计时器|timer=%s" % str(hud._turn_timer_label.get_global_rect()))
	print("TB|END")
	get_tree().quit(0)
