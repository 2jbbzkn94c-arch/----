extends Node
## 自由部署残留 验证：
## 玩过"自由部署"后 placement 残留；普通/竞技场入口应清空它，使 Battle 走正常部署。
## 运行：godot --headless --scene res://tests/FreeDeployRegression.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# 模拟"自由部署"残留：placement 非空、player_deck 为空
	GameState.player_placement[Vector2i(1, 9)] = "hero_06"
	GameState.enemy_placement[Vector2i(0, 1)] = "hero_13"
	GameState.player_deck = []
	GameState.enemy_deck = []
	# 普通/竞技场入口：清空 placement
	GameState.clear_placement()
	# 现在应走正常部署（player_deck 空 -> 用默认 deck，正常生成 roster）
	battle.player_dead = 0; battle.enemy_dead = 0
	battle.state = Battle.State.ENDED
	battle._place_units()
	# 正常部署会填 roster 且用默认卡组；自由部署则直接按 placement 放置、且"无默认英雄当首发"
	var has_default_units := battle.units.size() > 0
	var roster_not_empty := battle.player_roster.size() > 0 or battle.enemy_roster.size() > 0
	print("T1 清空placement后正常部署: units=%d roster(player=%d,enemy=%d) => %s" % [battle.units.size(), battle.player_roster.size(), battle.enemy_roster.size(), "PASS" if has_default_units else "FAIL"])

	# 对照：不清空 placement（残留）时走自由放置
	GameState.clear_placement()
	GameState.player_placement[Vector2i(1, 8)] = "hero_06"
	GameState.enemy_placement[Vector2i(0, 1)] = "hero_13"
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle._place_units()
	var placed_by_free := battle.units.size()
	print("T2 placement残留走自由放置: units=%d => %s" % [placed_by_free, "PASS" if placed_by_free == 2 else "FAIL"])

	get_tree().quit()
