extends Node
## 古拉博士吸血判定验证：
## 用目标**被攻击前**的 HP 判定是否吸血，而非受伤后的 HP。
## 运行：godot --headless --scene res://tests/GuraVerify.tscn
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
	# T1: 攻击前 HP 大于自己 -> 吸血；攻击后 HP 降到不大于自己，仍应吸血（用攻击前判定）
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var gura := spawn("hero_14", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	gura.hp = 8; gura.atk = 7; gura.refresh_stats()   # 攻击力 7
	var tgt := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	tgt.hp = 10; tgt.max_hp = 30; tgt.refresh_stats()   # 攻击前 10 > 8
	var g0 := gura.hp
	battle._do_attack(gura, tgt, false)
	await sleep_frames(200)
	# 攻击后 tgt.hp = 10 - 7 = 3 (< 8)，但攻击前 10 > 8 -> 应吸血
	var healed := gura.hp > g0
	print("T1 攻击前HP判定吸血: 古拉%d->%d 目标攻击后=%d => %s" % [g0, gura.hp, tgt.hp, "PASS" if healed else "FAIL"])

	# T2: 攻击前 HP 不大于自己 -> 不吸血（对照）
	clear_all()
	battle.state = Battle.State.PLAYER_INPUT
	var g2 := spawn("hero_14", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	g2.hp = 8; g2.atk = 7; g2.refresh_stats()
	var t2 := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	t2.hp = 4; t2.max_hp = 30; t2.refresh_stats()   # 攻击前 4 < 8
	var g20 := g2.hp
	battle._do_attack(g2, t2, false)
	await sleep_frames(200)
	print("T2 攻击前HP不大于自己不吸血: 古拉%d->%d => %s" % [g20, g2.hp, "PASS" if g2.hp == g20 else "FAIL"])

	get_tree().quit()
