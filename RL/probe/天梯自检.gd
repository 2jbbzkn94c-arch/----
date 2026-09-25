extends Node
## 【2026-09-24 一次性探针】天梯模式改动后的**解析 + 冒烟自检**：
##   ① `preload` 三个被改的大文件（Battle/Menu/HUD）⇒ 有 Parse Error 会在这里当场炸出来
##   ② 顺手体检 `LadderStore` / `Stats` 的新接口（连胜记账、快照读写、原子落盘）
## 退出码 0 = 全过。用法：godot --headless --path . --scene res://RL/probe/天梯自检.tscn

const BattleScript := preload("res://src/Battle.gd")
const MenuScript := preload("res://src/Menu.gd")
const HUDScript := preload("res://src/HUD.gd")

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var ok := true
	print("PROBE|① 脚本解析：Battle=%s Menu=%s HUD=%s" % [
		"ok" if BattleScript != null else "null",
		"ok" if MenuScript != null else "null",
		"ok" if HUDScript != null else "null"])

	# ② Stats：两个天梯模式 + 连胜记账（**先存后还原**，别把用户真实战绩/连胜写脏）
	print("PROBE|② 统计模式表 = %s" % str(Stats.MODES))
	var saved := {}
	for k in Stats.LADDER_MODES:
		saved[k] = [Stats.best_streak(k), Stats.current_streak(k)]
	var key := "sp_ladder"
	var before_best := Stats.best_streak(key)
	var before_cur := Stats.current_streak(key)
	Stats.reset_streak(key)
	Stats.note_streak_win(key)
	Stats.note_streak_win(key)
	var cur2 := Stats.current_streak(key)
	Stats.reset_streak(key)
	var cur0 := Stats.current_streak(key)
	var best := Stats.best_streak(key)
	print("PROBE|② 连胜路径：reset=%d → +2=%d → reset=%d · 最高=%d（改前 %d/%d）" % [before_cur, cur2, cur0, best, before_cur, before_best])
	if cur2 != 2 or cur0 != 0 or best < 2:
		ok = false
		print("PROBE|❌ 连胜记账不对")
	for k in Stats.LADDER_MODES:
		Stats.best_streaks[k] = saved[k][0]
		Stats.cur_streaks[k] = saved[k][1]
	Stats._save()
	print("PROBE|② 统计已还原：%s" % str(saved))

	# ③ LadderStore：begin → 存快照 → 读回 → 改盘 → 重新读（模拟"退出再进"）
	#   ⚠️ 新设计是"一变体一槽"：省略变体参数时取 `GameState.ladder_mode` ⇒ 这里显式传 "normal"
	LadderStore.begin("normal", ["hero_13", "hero_12", "hero_18"])
	var snap := { "ver": 1, "side": 0, "round": 3, "units": [{ "vars": { "hero_id": "hero_13", "hp": 7, "cell": Vector2i(2, 4), "statuses": { "poison": 2 } } }], "bombs": { Vector2i(1, 1): true } }
	LadderStore.save_snapshot(snap, "normal")
	var back := LadderStore.snapshot("normal")
	print("PROBE|③ 快照读回：round=%d side=%d units=%d bombs=%s" % [
		int(back.get("round", -1)), int(back.get("side", -1)),
		(back.get("units", []) as Array).size(), str(back.get("bombs", {}))])
	if int(back.get("round", -1)) != 3 or (back.get("units", []) as Array).size() != 1:
		ok = false
		print("PROBE|❌ 快照内容不对")
	# 重新 new 一份 ConfigFile 读盘，确认真的落到了 user://（而不是只在内存里）
	var cfg := ConfigFile.new()
	var load_err := cfg.load(LadderStore.SAVE_PATH)
	var from_disk: Dictionary = cfg.get_value("snaps", "normal", {}) if load_err == OK else {}
	print("PROBE|③ 落盘文件 %s：err=%d · 盘上 round=%d · run=%s" % [
		LadderStore.SAVE_PATH, load_err, int(from_disk.get("round", -1)), str(cfg.get_value("runs", "normal", {}))])
	if load_err != OK or int(from_disk.get("round", -1)) != 3:
		ok = false
		print("PROBE|❌ 存档没落到 user://")

	# ④ 清干净（别给用户留一个假存档）
	LadderStore.finish_run("normal")
	var cfg2 := ConfigFile.new()
	var still := cfg2.load(LadderStore.SAVE_PATH) == OK
	print("PROBE|④ 清档后文件还在吗 = %s" % str(still))
	if still:
		ok = false
		print("PROBE|❌ finish_run() 没删掉存档")

	# ⑤ 两个变体**状态分开**（用户 2026-09-24 要求「天梯普通场和竞技场状态分开」）
	GameState.ladder_mode = "normal"
	LadderStore.begin("normal", ["hero_13", "hero_12", "hero_18"])
	LadderStore.save_snapshot({ "ver": 1, "mark": "N", "round": 2 })
	GameState.ladder_mode = "arena"
	LadderStore.begin("arena", ["hero_24", "hero_09", "hero_20"])
	LadderStore.save_snapshot({ "ver": 1, "mark": "A", "round": 5 })
	var both := (LadderStore.has_run("normal") and LadderStore.has_run("arena")
		and String(LadderStore.snapshot("normal").get("mark", "")) == "N"
		and String(LadderStore.snapshot("arena").get("mark", "")) == "A")
	print("PROBE|⑤ 两变体并存：普通(第%s回合·卡组%s) · 竞技场(第%s回合·卡组%s) = %s" % [
		str(LadderStore.snapshot("normal").get("round", -1)), str(LadderStore.player_deck("normal")),
		str(LadderStore.snapshot("arena").get("round", -1)), str(LadderStore.player_deck("arena")), str(both)])
	if not both:
		ok = false
		print("PROBE|❌ 两个变体互相覆盖了")
	# 模拟重启：重新从盘上读
	LadderStore._load()
	var both2 := (LadderStore.has_run("normal") and LadderStore.has_run("arena")
		and String(LadderStore.snapshot("normal").get("mark", "")) == "N"
		and String(LadderStore.snapshot("arena").get("mark", "")) == "A")
	print("PROBE|⑤ 重读存档后仍各有各的 = %s" % str(both2))
	if not both2:
		ok = false
		print("PROBE|❌ 落盘/读回之后两变体串了")
	# 结束普通那一轮，竞技场那一轮必须原样还在
	LadderStore.finish_run("normal")
	var arena_kept: bool = LadderStore.has_run("arena") and not LadderStore.has_run("normal")
	print("PROBE|⑤ 结束天梯普通后：普通还在=%s · 竞技场还在=%s" % [
		str(LadderStore.has_run("normal")), str(LadderStore.has_run("arena"))])
	if not arena_kept:
		ok = false
		print("PROBE|❌ 结束一个变体把另一个也删了")
	LadderStore.finish_run("arena")
	LadderStore.finish_run("normal")
	GameState.ladder_mode = ""

	# ⑥ 菜单结构 + 选人页难度锁（真建一遍 Menu 场景去点弹框 / 进选人页）
	#    用户报过：「天梯普通模式怎么还可以选择噩梦以外的难度」—— 根因是选人页整页只建一次
	#    （`_build()` 在 _ready），建页时按模式决定"有没有下拉框" ⇒ 先玩普通模式再进天梯就一直带着下拉。
	#    现在下拉框永远建，口径由 `_refresh_team_diff_row()` 每次进页刷。
	var menu = load("res://scenes/Menu.tscn").instantiate()
	get_tree().root.add_child(menu)
	await get_tree().process_frame
	await get_tree().process_frame
	menu._ask_single_mode()
	await get_tree().process_frame
	var lv1 := _button_texts(menu)
	var lv1_ok: bool = lv1.has("普通模式") and lv1.has("竞技场模式") and lv1.has("天梯模式")
	print("PROBE|⑥ 单机模式弹框按钮 = %s" % str(lv1))
	menu._close_single_mode()
	menu._ask_ladder_variant()
	await get_tree().process_frame
	var lv2 := _button_texts(menu)
	var lv2_ok: bool = lv2.has("天梯普通模式") and lv2.has("天梯竞技场模式")
	print("PROBE|⑥ 天梯弹框按钮 = %s" % str(lv2))
	menu._close_ladder()
	if not (lv1_ok and lv2_ok):
		ok = false
		print("PROBE|❌ 菜单层级不对（应为 单机模式 → 普通/竞技场/天梯模式 → 天梯普通/天梯竞技场）")
	# 【天梯】"放弃"要再确认（用户要求）：弹确认层时本轮必须**还没被删**
	LadderStore.finish_run("normal")
	LadderStore.begin("normal", ["hero_13"])
	var ab_texts_before := _button_texts(menu)
	menu._ladder_ask_abandon("normal")
	await get_tree().process_frame
	var ab_texts := _button_texts(menu)
	var ab_ok: bool = LadderStore.has_run("normal") and ab_texts.has("确定放弃并重新开始") and ab_texts.has("取消")
	print("PROBE|⑥ 放弃再确认：本轮还在=%s · 弹层里出现=%s" % [
		str(LadderStore.has_run("normal")), str(ab_texts.filter(func(t): return t == "确定放弃并重新开始" or t == "取消"))])
	menu._close_ladder()
	if not ab_ok:
		ok = false
		print("PROBE|❌ 放弃没有走再确认（或确认层还没弹就把档删了）")
	LadderStore.finish_run("normal")
	# 选人页：天梯 ⇒ 下拉隐藏 + 强制噩梦；普通 ⇒ 下拉显示
	GameState.ladder_mode = "normal"
	menu._show_team_view()
	await get_tree().process_frame
	var lock_ok: bool = menu._diff_opt != null and not menu._diff_opt.visible and GameState.ai_difficulty == 3
	print("PROBE|⑥ 天梯选人页：难度下拉可见=%s · ai_difficulty=%d（应 false / 3）" % [
		str(menu._diff_opt.visible), GameState.ai_difficulty])
	GameState.ladder_mode = ""
	GameState.ai_difficulty = 1
	menu._show_team_view()
	await get_tree().process_frame
	var unlock_ok: bool = menu._diff_opt.visible and menu._diff_opt.selected == 1
	print("PROBE|⑥ 普通选人页：难度下拉可见=%s · 选中=%d（应 true / 1）" % [
		str(menu._diff_opt.visible), menu._diff_opt.selected])
	if not (lock_ok and unlock_ok):
		ok = false
		print("PROBE|❌ 选人页难度行口径不对")
	menu.queue_free()
	for i in 3:
		await get_tree().process_frame

	print("PROBE|%s" % ("全部通过 ✅" if ok else "有失败项 ❌"))
	print("PROBE|END")
	get_tree().quit(0 if ok else 1)

# 递归收集当前界面上所有按钮文案（给 ⑥ 的菜单层级检查用）
func _button_texts(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is Button and (c as Button).text != "":
			out.append((c as Button).text)
		out.append_array(_button_texts(c))
	return out
