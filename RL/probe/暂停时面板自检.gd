extends Node
## 【2026-09-29 一次性探针】用户报「部署阶段，点击菜单后，队伍列表会弹出来」。
## 做法：拉起真实战斗场景 → 进部署态 → 记录一次 → 调 `_on_pause_pressed()`（= 点菜单）→ 再记录。
## 每次打印：`battle.state` · 替补/队伍面板是否存在 · `_team_panel_open/_forced/_sub_picking()` ·
##   暂停浮层与部署面板是否存在、以及**它们在 HUD 子节点里的序号**（序号大 = 画在上面）。
## 输出：每行 `PB|...`，末尾 `PB|END`。

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
	_dump(hud, "部署中_点菜单前")
	hud._on_pause_pressed()
	for i in 12:
		await get_tree().process_frame
	_dump(hud, "点了菜单之后")
	# 暂停期间再强行重建一次部署面板（复现"卡池盖在暂停黑底上"那条路）⇒ 序号不该变大
	hud._show_deploy_panel()
	for i in 4:
		await get_tree().process_frame
	_dump(hud, "暂停中_又喊了一次重建")
	print("PB|END")
	get_tree().quit(0)

func _dump(hud, tag: String) -> void:
	var order: Array = []
	for c in hud.get_children():
		order.append("%s@%d" % [c.get_class(), c.get_index()])
	print("PB|%s|state=%d|pause_ov=%s@%s|deploy_ov=%s@%s|team_panel=%s@%s|open=%s|forced=%s|picking=%s" % [
		tag, battle.state,
		str(hud._pause_overlay != null), str(_idx(hud._pause_overlay)),
		str(hud._deploy_overlay != null), str(_idx(hud._deploy_overlay)),
		str(hud._team_panel != null), str(_idx(hud._team_panel)),
		str(hud._team_panel_open), str(hud._team_panel_forced), str(hud._sub_picking())])
	print("PB|%s|HUD子节点顺序=%s" % [tag, " ".join(order)])

func _idx(c) -> int:
	if c == null or not is_instance_valid(c):
		return -1
	return c.get_index()
