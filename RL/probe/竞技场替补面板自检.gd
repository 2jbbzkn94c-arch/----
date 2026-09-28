extends Node
## 【2026-09-28 一次性探针】竞技场「2 选 1 时替补队伍面板该默认打开」自检 —— 用户实报
##   「怎么竞技场2选1的时候，替补队伍还是没有默认打开」。
##
## 做法：真的把战斗场景拉起来（`res://scenes/Main.tscn`，与 `RL/probe/战斗布局自检.gd` 同一套路），
##   然后**摆出竞技场的三个状态**逐一量：
##     ① `ARENA_DRAFT`（2 选 1 选人态，`GameState.arena_mode = true` + 已选 2 人）
##     ② `DEPLOY`（选完进入部署；用户原话"直到部署完成再关闭"）
##     ③ `PLAYER_INPUT`（部署完对局中 ⇒ 必须**收回**，由用户点箭头才拉出）
##   每个状态量：`_should_force_team_panel()` · `_team_panel_forced` · **面板节点在不在** · 面板里几张卡 ·
##   箭头按钮 visible / disabled。对照臂：`arena_mode = false` 的同三个状态（普通模式不该被强制打开）。
##
## 输出：每行 `ARENA|...`，末尾 `ARENA|END`。

var battle: Battle
var hud

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	hud = battle._hud
	if hud == null:
		print("ARENA|**没拿到 HUD** ✗")
		print("ARENA|END")
		get_tree().quit(0)
		return
	# 摆一副"竞技场已选 2 人"的牌（面板要能显示出这两张）
	battle._arena_picked = ["hero_41", "hero_30"]
	battle._arena_enemy = ["hero_12"]
	battle._arena_pending = []
	battle._arena_player_rounds = 0
	battle._arena_enemy_rounds = 0
	for state_desc in [
		{ "tag": "① 竞技场 2选1（ARENA_DRAFT）", "arena": true, "state": Battle.State.ARENA_DRAFT },
		{ "tag": "② 竞技场 部署（DEPLOY）", "arena": true, "state": Battle.State.DEPLOY },
		{ "tag": "③ 竞技场 对局中（PLAYER_INPUT）", "arena": true, "state": Battle.State.PLAYER_INPUT },
		{ "tag": "④ 对照·普通模式 ARENA_DRAFT 态", "arena": false, "state": Battle.State.ARENA_DRAFT },
	]:
		GameState.arena_mode = bool(state_desc["arena"])
		battle.state = int(state_desc["state"])
		# 面板显隐是"每帧 `_refresh_controls()`"驱动的；这里手动走一遍同一条路（探针不依赖帧循环）
		hud._sync_arena_team_panel()
		hud._refresh_team_toggle()
		await get_tree().process_frame
		hud._sync_arena_team_panel()
		var panel = hud._team_panel
		var cards := 0
		if panel != null and is_instance_valid(panel):
			for ch in panel.get_children():
				cards += ch.get_child_count()
		print("ARENA|%s|force=%s ｜ forced=%s ｜ 面板=%s（子节点 %d）｜ 箭头 visible=%s disabled=%s ｜ _player_team_ids=%s" % [
			str(state_desc["tag"]), str(hud._should_force_team_panel()), str(hud._team_panel_forced),
			("有" if panel != null else "**没有**"), (panel.get_child_count() if panel != null else -1),
			str(hud._team_toggle_btn.visible if hud._team_toggle_btn != null else "无按钮"),
			str(hud._team_toggle_btn.disabled if hud._team_toggle_btn != null else "无按钮"),
			str(battle._player_team_ids())])
	print("ARENA|END")
	get_tree().quit(0)
