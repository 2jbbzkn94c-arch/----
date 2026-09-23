extends Node
## 【2026-09-23 深夜·一次性探针】用户报「连点两次重开 ⇒ 烛火/圣光的移动范围多 1 格」。
##
## 复现方式 = 用户那条：**自由部署**（三个落点都填好 ⇒ `reset_match()` 直接 `_place_units()` + `_start_match()`，
##   不像普通模式那样还要过选卡组/部署面板），三个落点里放【风语者 + 烛火 + 圣光】，
##   然后**连点两次** `HUD._on_restart(false)`（第二次落在第一次的开局演出 await 里）。
##
## 读什么：每个我方单位的 `move_buff`（风语者光环发的额度）与 `effective_move()`。
##   · 正常：风语者自己 0（它不吃自己的光环）、队友各 **1**
##   · 重开竞态未修：两条开局序列都遍历**当前** units ⇒ 新风语者被触发两次 ⇒ 队友各 **2**（多 1 格）
## 场景 C 是"机制自证"：同一局里再手动跑一条 `_run_side_skills()`（= 第二条序列）⇒ 队友 +1 ⇒
##   说明"队友多 1 格、风语者自己不变"这个签名就是"回合开始序列跑了两次"，与用户看到的现象一致。
##
## 输出：每行 `PROBE|...`（含中文名，用 UTF-8 输出），末尾 `PROBE|END`。

var _b: Battle = null

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Engine.time_scale = 10.0
	GameState.reset_online()
	GameState.dual_control = false
	GameState.no_death_limit = false
	GameState.arena_mode = false
	GameState.pick_deck_in_battle = false
	GameState.ai_difficulty = 3
	# 自由部署：三个落点全填（用户那局的阵容：风语者 / 烛火 / 圣光）
	GameState.player_placement = {
		Vector2i(0, 6): "hero_43", Vector2i(2, 6): "hero_17", Vector2i(4, 6): "hero_22",
	}
	GameState.enemy_placement = {
		Vector2i(0, 1): "hero_15", Vector2i(2, 1): "hero_12", Vector2i(4, 1): "hero_16",
	}
	_b = load("res://scenes/Main.tscn").instantiate() as Battle
	_b.set_random_seed(777001)
	get_tree().root.add_child(_b)
	if not await _wait_input(30.0):
		print("PROBE|FATAL|did_not_reach_input|state=%d" % int(_b.state))
		await _done()
		return
	_rep("A_first_match")
	# 连点两次重开：两次调用之间不 await ⇒ 第二次必然落在第一次的开局演出里（= 用户的双击）
	_hud()._on_restart(false)
	_hud()._on_restart(false)
	if not await _wait_input(30.0):
		print("PROBE|FATAL|did_not_reach_input_after_double|state=%d" % int(_b.state))
		await _done()
		return
	_rep("B_after_double_restart")
	# C：机制自证 —— 同一局里再手动跑一条开局序列（模拟"第二条序列也活到了回合开始技"）
	await _b._run_side_skills(GameState.SIDE_PLAYER)
	await _frames(4)
	_rep("C_after_extra_side_skills")
	await _done()

func _rep(tag: String) -> void:
	var parts: Array[String] = []
	for u in _b.units:
		if u == null or not is_instance_valid(u) or u.faction != DataRegistry.Faction.PLAYER:
			continue
		parts.append("%s buff=%d base=%d emove=%d" % [
			u.display_name, u.move_buff, u.move_range, u.effective_move()])
	print("PROBE|%s|state=%d|%s" % [tag, int(_b.state), " ｜ ".join(parts)])

func _hud() -> HUD:
	for c in _b.get_children():
		if c is HUD:
			return c as HUD
	return null

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _wait_input(limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if _b.state == Battle.State.PLAYER_INPUT:
			return true
		await get_tree().process_frame
		t += 1.0 / 60.0
	return false

func _done() -> void:
	print("PROBE|END")
	get_tree().quit(0)
