extends Node
## 快速测试场放置验证：用合法玩家格(行8)放置，确认进对局后我方能正常生成。
## 运行：godot --headless --scene res://tests/QuickDeployVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func _run() -> void:
	GameState.clear_placement()
	# 模拟 QuickTest._on_start 放置（用合法格行8）
	var cells := [Vector2i(2, 8), Vector2i(4, 8), Vector2i(1, 8)]
	var picks := ["hero_06", "hero_17", "hero_26"]
	for i in cells.size():
		GameState.player_placement[cells[i]] = picks[i]
	GameState.enemy_placement[Vector2i(1, 0)] = "hero_13"
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.state = Battle.State.ENDED
	battle._place_units()
	var my_units := 0
	var en_units := 0
	for u in battle.units:
		if u.faction == DataRegistry.Faction.PLAYER:
			my_units += 1
		else:
			en_units += 1
	print("T1 自由放置我方生成: 我方=%d 敌方=%d => %s" % [my_units, en_units, "PASS" if my_units >= 3 else "FAIL"])
	get_tree().quit()
