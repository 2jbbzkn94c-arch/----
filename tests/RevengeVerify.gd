extends Node
## 复仇者无限反击验证：
## 在同一回合"已反击过一次"后再次被贴身攻击，复仇者仍能反击（无限）；普通单位不能。
## 运行：godot --headless --scene res://tests/RevengeVerify.tscn
var battle: Battle

func _ready() -> void:
	battle = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(battle)
	_run.call_deferred()

func clear_all() -> void:
	for u in battle.units:
		if is_instance_valid(u):
			u.queue_free()
	battle.units.clear()
	battle.occupancy.clear()
	battle.bombs.clear()
	battle.buff_items.clear()
	battle.obstacles.clear()
	battle.graves.clear()
	battle.player_dead = 0
	battle.enemy_dead = 0
	battle.selected = null
	battle.state = Battle.State.ENDED

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# T1: 复仇者已反击过一次，仍可再次反击（无限）
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var av := spawn("hero_23", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var atk := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	atk.atk = 1
	atk.hp = 30
	atk.max_hp = 30
	atk.refresh_stats()
	av.counter_used_this_turn = true   # 模拟本回合已反击过一次
	var av0 := av.hp
	battle._do_attack(atk, av, false)   # 敌人攻击复仇者 -> 应触发反击
	await sleep_frames(200)
	print("T1 复仇者已反击仍可再次反击: atkHP=%d(原30) => %s" % [atk.hp, "PASS" if atk.hp < 30 else "FAIL"])

	# T2: 普通单位已反击过一次，不再反击（对照）
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var normal := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var atk2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	atk2.atk = 1
	atk2.hp = 30
	atk2.max_hp = 30
	atk2.refresh_stats()
	normal.counter_used_this_turn = true
	battle._do_attack(atk2, normal, false)
	await sleep_frames(200)
	print("T2 普通单位已反击不再次反击: atkHP=%d(原30) => %s" % [atk2.hp, "PASS" if atk2.hp == 30 else "FAIL"])

	get_tree().quit()
