extends Node
## 任意方式进入炸弹格均触发验证：
## 击退 / 拉近 / 换位 落到炸弹格 => 非炸弹人爆炸、炸弹人安全。
## 运行：godot --headless --scene res://tests/BombAnywayVerify.tscn
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

func spawn(hid: String, f: int, c: Vector2i) -> Unit:
	return battle._spawn_unit(hid, f, c)

func _run() -> void:
	# T1: 击退到炸弹格 -> 非炸弹人爆炸
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	# 目标在 (4,8)，攻击者在 (3,8)（直线），击退目标到 (5,8)，(5,8) 放炸弹
	# 目标在 (4,8)，攻击者在 (3,8)（直线），击退目标到落点 (5,7)，(5,7) 放炸弹
	var target := spawn("hero_06", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	target.hp = 20; target.max_hp = 20; target.refresh_stats()
	battle.bombs[Vector2i(5, 5)] = true   # 实际击退落点（轴向）
	if battle.board_view:
		battle.board_view.bombs = battle.bombs
	var t0 := target.hp
	battle._knockback(target, Vector2i(3, 6))   # 击退，落点 (5,5)=炸弹
	await battle.get_tree().create_timer(0.3).timeout
	var exploded := battle.bombs.has(Vector2i(5, 5)) == false
	print("T1 击退到炸弹爆炸: 目标%d->%d 炸=%s cell=%s => %s" % [t0, target.hp, str(exploded), str(target.cell), "PASS" if target.hp < t0 and exploded else "FAIL"])

	# T2: 换位（swap）把非炸弹人换到炸弹格 -> 爆炸
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var a := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var b := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	b.hp = 20; b.max_hp = 20; b.refresh_stats()
	battle.bombs[Vector2i(3, 6)] = true   # 把 a 换到炸弹格
	if battle.board_view:
		battle.board_view.bombs = battle.bombs
	var b0 := b.hp
	battle._swap_units(a, b)   # a 换到 (4,8)，b 换到 (3,8)=炸弹
	await battle.get_tree().create_timer(0.3).timeout
	# b 现应站在炸弹格 (3,8) 爆了（hp下降）
	print("T2 换位到炸弹爆炸: b=%d->%d => %s" % [b0, b.hp, "PASS" if b.hp < b0 else "FAIL"])

	# T3: 炸弹人被击退到炸弹格安全
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var atk3 := spawn("hero_13", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	var bom := spawn("hero_35", DataRegistry.Faction.ENEMY, Vector2i(4, 6))
	bom.hp = 20; bom.max_hp = 20; bom.refresh_stats()
	battle.bombs[Vector2i(5, 5)] = true
	if battle.board_view:
		battle.board_view.bombs = battle.bombs
	var bom0 := bom.hp
	battle._knockback(bom, Vector2i(3, 6))   # 击退炸弹人到 (5,5)=炸弹
	await battle.get_tree().create_timer(0.3).timeout
	print("T3 炸弹人被击退安全: hp=%d->%d => %s" % [bom0, bom.hp, "PASS" if bom.hp == bom0 else "FAIL"])

	get_tree().quit()
