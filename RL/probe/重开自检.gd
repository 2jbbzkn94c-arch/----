extends Node
## 【2026-09-22 一次性探针】"点重开之后部署界面没了"复现 —— 跑完即退，**不改任何生产代码**。
##
## 查什么：单机正常流程（入场选卡组 → 部署）走到部署态之后，分别用
##   ① HUD「重开」按钮走的那条路（`HUD._on_restart(false)`）
##   ② 结算界面的「再战一局」（`HUD._on_restart(true)`）
##   ③ 直接调 `Battle.reset_match(false)`（对照组）
## 各重开一次，逐条打印：battle.state / 双方卡池人数 / 卡组人数 / HUD 上"部署面板 / 选卡组面板 / 竞技场面板"
## 到底在不在（`_deploy_overlay != null`）、以及 `_deck_pick_match`、`GameState.pick_deck_in_battle`。
##
## 用法：
##   & RL\train\跑Godot隔离.ps1 -Tag restart -TimeoutSec 600 -Args @('--headless','--path',(Get-Location).Path,'--scene','res://RL/probe/重开自检.tscn')
## 输出：每行 `PROBE|...`（ASCII），末尾 `PROBE|END`。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = true
	GameState.ai_difficulty = 3
	GameState.player_deck = []
	GameState.enemy_deck = []
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(777001)
	get_tree().root.add_child(_b)
	print("PROBE|cfg|pick_deck_in_battle=%s|arena=%s|difficulty=%d" % [
		str(GameState.pick_deck_in_battle), str(GameState.arena_mode), GameState.ai_difficulty])
	if not await _wait_state([Battle.State.DECK_PICK], 10.0):
		print("PROBE|FATAL|did_not_reach_DECK_PICK|state=%d" % int(_b.state))
		await _done()
		return
	_rep("A_before_pick")
	# 模拟玩家选完卡组（= HUD 面板点"出战"那条路）
	_b._start_with_player_deck(["hero_01", "hero_06", "hero_12", "hero_22", "hero_33"])
	await _frames(4)
	if not await _wait_state([Battle.State.DEPLOY, Battle.State.PLACE_DEPLOY], 10.0):
		print("PROBE|FATAL|did_not_reach_DEPLOY|state=%d" % int(_b.state))
		await _done()
		return
	_rep("B_in_deploy")
	# ① 重开按钮那条路
	_hud()._on_restart(false)
	await _frames(6)
	_rep("C_after_restart_btn")
	# 重开之后走一遍"选卡组 → 部署"，看第二次还能不能到部署态
	if _b.state == Battle.State.DECK_PICK:
		_b._start_with_player_deck(["hero_01", "hero_06", "hero_12", "hero_22", "hero_33"])
		await _frames(4)
	var ok2 := await _wait_state([Battle.State.DEPLOY, Battle.State.PLACE_DEPLOY], 10.0)
	print("PROBE|C2|reached_deploy_after_restart=%s|state=%d" % [str(ok2), int(_b.state)])
	_rep("C2_after_restart_deploy")
	# ② "再战一局"那条路（redraft=true）
	_hud()._on_restart(true)
	await _frames(6)
	_rep("D_after_rematch")
	# ③ 对照组：直接 reset_match(false)
	_b.reset_match(false)
	await _frames(6)
	_rep("E_after_reset_direct")
	await _done()

func _rep(tag: String) -> void:
	var hud := _hud()
	var deploy_ui := "无HUD"
	var deck_ui := "-"
	var arena_ui := "-"
	if hud != null:
		deploy_ui = "有" if hud._deploy_overlay != null else "**空**"
		deck_ui = "有" if hud._deck_pick_overlay != null else "**空**"
		arena_ui = "有" if hud._arena_panel != null else "**空**"
	print("PROBE|%s|state=%d|deploy_side=%d|player_pool=%d|enemy_pool=%d|deck=%d/%d|deck_pick_match=%s|pdb=%s|UI部署=%s|UI选卡组=%s|UI竞技场=%s|placement=%d/%d" % [
		tag, int(_b.state), int(_b._deploy_side), _b.player_pool.size(), _b.enemy_pool.size(),
		GameState.player_deck.size(), GameState.enemy_deck.size(), str(_b._deck_pick_match),
		str(GameState.pick_deck_in_battle), deploy_ui, deck_ui, arena_ui,
		GameState.player_placement.size(), GameState.enemy_placement.size()])

func _hud() -> HUD:
	for c in _b.get_children():
		if c is HUD:
			return c as HUD
	return null

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_state(states: Array, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if states.has(_b.state):
			return true
		await get_tree().process_frame
		t += 1.0 / 60.0
	return false

func _done() -> void:
	print("PROBE|END")
	get_tree().quit(0)
