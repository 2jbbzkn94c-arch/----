extends Node
## 部署出生区高亮验证：
## 敌方出生区(顶部)应全程标红；放位阶段/取消后都不应消失。
## 运行：godot --headless --scene res://tests/DeployZoneVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _count_colored(zone_faction: int, is_red: bool) -> int:
	var cells := battle._spawn_cells(zone_faction)
	var n := 0
	for c in cells:
		if battle._preview_cells.has(c):
			var col: Color = battle._preview_cells[c]
			if is_red and col.r > 0.7 and col.b < 0.5:
				n += 1
			elif not is_red and col.r < 0.5 and col.b > 0.6:
				n += 1
	return n

func _has_red_enemy_zone() -> bool:
	var cells := battle._spawn_cells(DataRegistry.Faction.ENEMY)
	var red := 0
	for c in cells:
		if battle._preview_cells.has(c):
			var col: Color = battle._preview_cells[c]
			if col.r > 0.7 and col.b < 0.5:
				red += 1
	return red == cells.size()

func _run() -> void:
	GameState.clear_placement()
	GameState.arena_mode = false
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_13", "hero_13"]
	battle._begin_deployment()
	# 敌方出生区(顶部)是否标红
	print("T1 部署开始敌方出生区标红: %s => %s" % [str(_has_red_enemy_zone()), "PASS" if _has_red_enemy_zone() else "FAIL"])

	# 玩家选人进入放位阶段：敌方出生区应保留红色
	battle._on_deploy_pick("hero_06")
	print("T2 放位阶段敌方出生区保留红: %s => %s" % [str(_has_red_enemy_zone()), "PASS" if _has_red_enemy_zone() else "FAIL"])

	# 取消选人回到选人状态：敌方出生区应保留红色
	battle._pending_deploy = "hero_06"
	battle.state = Battle.State.PLACE_DEPLOY
	battle._on_deploy_pick_again("hero_06")
	print("T3 取消后敌方出生区保留红: %s => %s" % [str(_has_red_enemy_zone()), "PASS" if _has_red_enemy_zone() else "FAIL"])

	get_tree().quit()
