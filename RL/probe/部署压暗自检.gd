extends Node
## 【2026-09-28 一次性探针·临时】部署卡池"亮/暗"自检 —— 用户报：
##   「如果是对方的先手，我方的替补队伍会先亮着，到对方上人才会暗下来」
##
## 第一版（已跑）：直接进部署、`_deploy_side=1` ⇒ 卡池从第一帧就是**暗**的（亮=0 暗=5）⇒ 不是卡池的锅。
## 本版：**走真实的竞技场路径**（2 选 1 直接判完 ⇒ 战斗开始横幅 ⇒ 部署，强制对方先手），
##   每 0.2 秒 dump 三块 UI 的存在与亮/暗：`_team_panel`（替补队伍面板）、`_deploy_overlay`（部署卡池）、`_arena_panel`。
## 输出：每行 `DBG|...`，末尾 `DBG|END`。

var battle: Battle
var t := 0.0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	battle = (load("res://scenes/Main.tscn") as PackedScene).instantiate() as Battle
	add_child(battle)
	for i in 3:
		await get_tree().process_frame
	# 竞技场 + 强制对方先手
	GameState.arena_mode = true
	GameState.ladder_mode = "arena"
	battle._first_side_decided = true
	battle._deploy_side = 1
	battle._first_side = GameState.SIDE_ENEMY
	# 2 选 1 直接判完（8 轮记满）⇒ 立刻走"选完 ⇒ 战斗开始 ⇒ 部署"
	battle._arena_picked = ["hero_06", "hero_13", "hero_12", "hero_25", "hero_34", "hero_10", "hero_11", "hero_14"]
	battle._arena_enemy = ["hero_15", "hero_16", "hero_17", "hero_18", "hero_19", "hero_20", "hero_21", "hero_22"]
	battle._arena_player_rounds = 4
	battle._arena_enemy_rounds = 4
	battle._arena_pool = ["hero_23", "hero_24"]
	battle.state = Battle.State.ARENA_DRAFT
	battle._battle_announced = false        # 让"战斗开始"横幅 + 1.2 秒停顿照真实走一遍
	battle._show_arena_round()
	while t < 6.0:
		await get_tree().create_timer(0.1).timeout
		t += 0.1
		_dump()
	print("DBG|END")

func _dim_counts(node) -> Array:
	var bright := 0
	var dim := 0
	if node != null and is_instance_valid(node):
		for c in node.find_children("*", "HexCard", true, false):
			if c.disabled_draw:
				dim += 1
			else:
				bright += 1
	return [bright, dim]

func _dump() -> void:
	var hud = battle._hud
	if hud == null:
		print("DBG|t=%.1f HUD 未建" % t)
		return
	var tp := _dim_counts(hud._team_panel)
	var dp := _dim_counts(hud._deploy_overlay)
	var ap := _dim_counts(hud._arena_panel)
	print("DBG|t=%.1f state=%d side=%d 替补面板(亮%d 暗%d, 存在%s) 卡池(亮%d 暗%d) 二选一(存在%s) forced=%s 敌上=%d" % [
		t, battle.state, battle._deploy_side, tp[0], tp[1], str(hud._team_panel != null),
		dp[0], dp[1], str(hud._arena_panel != null), str(hud._team_panel_forced),
		battle.enemy_deployed.size()])
