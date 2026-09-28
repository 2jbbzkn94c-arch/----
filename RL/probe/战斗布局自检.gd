extends Node
## 【2026-09-27 一次性探针·临时】战斗布局自检 —— 用户要求三件事：
##   ① **棋盘放大、宽度接近填满** ② **结束回合按钮往上移一点** ③ **按钮行右边贴边那个箭头：点击拉出替补队伍列表**
##
## 做法：**真的把战斗场景拉起来**（`res://scenes/Main.tscn`，与 `tests/SubVerify.gd` 同一套路），
##   等两帧后量真实矩形：棋盘包围盒（与 `Battle._board_origin()` 同款算法）、视口宽、
##   「结束回合」按钮、右贴边箭头、以及**点箭头前后**替补面板的存在/矩形 —— 顺带量一次重叠判定。
##
## 输出：每行 `LAY|...`，末尾 `LAY|END`。

var battle: Battle

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	# 摆一个"对局中"的局面（否则停在部署态：那时箭头本该隐藏、替补面板也不该出现）
	battle.player_roster = ["hero_42", "hero_43"]
	battle.enemy_roster = ["hero_06"]
	battle.state = Battle.State.PLAYER_INPUT
	battle._spawn_unit("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	battle._spawn_unit("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	for i in 2:
		await get_tree().process_frame
	var hud = battle._hud
	hud._refresh_team_panel()
	hud._refresh_team_toggle()
	for i in 2:
		await get_tree().process_frame

	var vs := get_viewport().get_visible_rect().size
	var g: HexGrid = battle.grid
	var hs: float = battle.hex_size
	var minx := INF
	var miny := INF
	var maxx := -INF
	var maxy := -INF
	for cell in g.all_cells():
		var p := g._raw_cell_to_world(cell)
		minx = min(minx, p.x)
		miny = min(miny, p.y)
		maxx = max(maxx, p.x)
		maxy = max(maxy, p.y)
	var org: Vector2 = battle._board_origin()
	var left: float = org.x + minx - hs
	var top: float = org.y + miny - hs * 0.866
	var bw: float = (maxx - minx) + 2.0 * hs
	var bh: float = (maxy - miny) + 2.0 * hs * 0.866
	print("LAY|视口|宽=%.0f 高=%.0f" % [vs.x, vs.y])
	print("LAY|棋盘|hex_size=%.1f|宽=%.0f（占视口 %.0f%%）|高=%.0f|左=%.0f 右=%.0f|顶=%.0f 底=%.0f" % [
		hs, bw, bw * 100.0 / vs.x, bh, left, left + bw, top, top + bh])
	var btn_y: float = hud._btn_row_y()
	print("LAY|按钮带|顶=%.0f（屏幕高 − %.0f − %.0f）｜棋盘底=%.0f ⇒ %s" % [
		btn_y, HUD.END_BTN_IMG_H, HUD.BTN_ROW_FOOT_GAP, top + bh,
		("不重叠 ✓ 余 %.0fpx" % (btn_y - (top + bh)) if top + bh <= btn_y else "**重叠 ✗**")])
	if hud._end_btn != null:
		print("LAY|结束回合按钮|rect=%s" % str(hud._end_btn.get_global_rect()))
	# 音量键（2026-09-28 用户要求移到右上角、暂停左边）
	for ch in hud._ui_root.get_children():
		if ch is HUD.VolumeControl:
			print("LAY|音量键|rect=%s｜暂停按钮 rect=%s" % [
				str((ch as Control).get_global_rect()),
				str(hud._pause_btn.get_global_rect() if hud._pause_btn != null else Rect2())])
	var arrow: Button = hud.find_child("TeamToggle", true, false) as Button
	if arrow == null:
		print("LAY|箭头|**没找到 TeamToggle 节点** ✗")
	else:
		print("LAY|箭头|rect=%s|文案=%s|可见=%s｜视口右缘=%.0f ⇒ 贴边距=%.0f" % [
			str(arrow.get_global_rect()), arrow.text, str(arrow.visible), vs.x,
			vs.x - arrow.get_global_rect().end.x])
	print("LAY|初始（收起）|替补面板=%s" % ("存在" if hud._team_panel != null else "不存在 ✓"))
	# ① 点箭头 ⇒ 从右往左滑出（等 ~0.23s 让 tween 走完再量）
	hud._on_team_toggle()
	for i in 14:
		await get_tree().process_frame
	var tp = hud._team_panel
	if tp != null:
		var pr: Rect2 = tp.get_global_rect()
		var aleft: float = arrow.get_global_rect().position.x if arrow != null else 0.0
		print("LAY|点一下|替补面板=rect=%s｜右缘=%.0f（目标中心 %.0f=视口中心）｜顶=%.0f 底=%.0f｜按钮带 1128..1240 ⇒ %s｜箭头左沿=%.0f ⇒ %s｜箭头文案=%s" % [
			str(pr), pr.end.x, (vs.x - pr.size.x) * 0.5 + pr.size.x * 0.5, pr.position.y, pr.end.y,
			("覆盖按钮带 ✓（用户要求）" if pr.position.y <= btn_y and pr.end.y >= btn_y else "没盖住按钮带 ✗"),
			aleft, ("箭头没被盖住 ✓" if pr.end.x <= aleft else "**箭头被自己盖住了 ✗**"),
			(arrow.text if arrow != null else "-")])
	else:
		print("LAY|点一下|**替补面板不存在 ✗**")
	# ② 再点 ⇒ 收回
	hud._on_team_toggle()
	for i in 2:
		await get_tree().process_frame
	print("LAY|再点一下|替补面板=%s｜箭头文案=%s" % [
		("存在 ✗" if hud._team_panel != null else "不存在 ✓"), (arrow.text if arrow != null else "-")])
	# ③ 选替补阶段 ⇒ 必须强制显示（与用户收没收起无关）
	battle.state = Battle.State.SUBSTITUTING
	hud._refresh_team_panel()
	for i in 2:
		await get_tree().process_frame
	print("LAY|选替补阶段|替补面板=%s｜箭头文案=%s" % [
		("存在 ✓" if hud._team_panel != null else "**不存在 ✗**"), (arrow.text if arrow != null else "-")])
	# ④ 部署阶段：那张"开局选人"卡片行现在和放大了的棋盘有没有重叠？（用户会立刻看到）
	battle.state = Battle.State.DEPLOY
	hud._show_deploy_panel()
	for i in 2:
		await get_tree().process_frame
	var ov = hud._deploy_overlay
	var pool_rect := Rect2()
	var pool_found := false
	if ov != null and ov.get_child_count() > 0:
		var p0 = ov.get_child(0)
		if p0 is Control:
			pool_rect = (p0 as Control).get_global_rect()
			pool_found = true
	if hud._deploy_timer_label != null:
		print("LAY|部署倒计时大字|rect=%s｜棋盘中心=%.0f,%.0f" % [str(hud._deploy_timer_label.get_global_rect()),
			hud._board_center_px().x, hud._board_center_px().y])
	print("LAY|部署阶段|卡池宿主=%s%s｜箭头可见=%s｜结束回合可见=%s｜棋盘底=%.0f ⇒ %s" % [
		("rect=" + str(pool_rect)) if pool_found else "**没找到**",
		("|顶=%.0f" % pool_rect.position.y) if pool_found else "",
		str(arrow.visible if arrow != null else false),
		str(hud._end_btn.visible if hud._end_btn != null else false), top + bh,
		("**与棋盘重叠 %.0fpx ✗**" % ((top + bh) - pool_rect.position.y) if pool_found and pool_rect.position.y < top + bh else "不重叠 ✓")])
	# ⑤ 回到对局态：卡片行该消失、结束回合该回来
	battle.state = Battle.State.PLAYER_INPUT
	hud._show_deploy_panel()
	hud._refresh_controls()
	for i in 2:
		await get_tree().process_frame
	print("LAY|回到对局|卡池=%s｜结束回合可见=%s｜箭头可见=%s" % [
		("还在 ✗" if hud._deploy_overlay != null else "已消失 ✓"),
		str(hud._end_btn.visible if hud._end_btn != null else false),
		str(arrow.visible if arrow != null else false)])
	print("LAY|END")
	get_tree().quit(0)
