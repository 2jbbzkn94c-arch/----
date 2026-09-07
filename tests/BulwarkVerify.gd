extends Node
## 塔盾主动减免验证：
## 塔盾站队友旁边，队友受 >1 伤害时，队友实际伤害-1、塔盾扣1血（代替承受）。
## 运行：godot --headless --scene res://tests/BulwarkVerify.tscn
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
	# T1: 塔盾紧邻队友，队友被反击受 >1 伤害 -> 队友少受1、塔盾扣1
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var bul := spawn("hero_11", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	bul.hp = 20; bul.max_hp = 20; bul.refresh_stats()
	var ally := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	ally.hp = 20; ally.max_hp = 20; ally.refresh_stats()
	# 敌方远程/近战攻击队友（距离2用远程，能让队友受伤≥3验证>1）
	var foe := spawn("hero_13", DataRegistry.Faction.ENEMY, Vector2i(6, 6))
	foe.atk = 4; foe.hp = 20; foe.max_hp = 20; foe.refresh_stats()
	var ally0 := ally.hp
	var bul0 := bul.hp
	# 直接模拟：friendly take_damage >1，经 _bulwark_absorb 减免
	ally.take_damage(4, false, true)   # 反击伤害4
	await sleep_frames(60)
	var ally_lost := ally0 - ally.hp
	var bul_lost := bul0 - bul.hp
	print("T1 塔盾减免队友伤害: 队友掉%d(应3) 塔盾掉%d(应1) => %s" % [ally_lost, bul_lost, "PASS" if ally_lost == 3 and bul_lost == 1 else "FAIL"])

	# T2: 伤害为1时不减免（塔盾只对>1生效）
	clear_all()
	battle.state = Battle.State.ENEMY_TURN
	var bul2 := spawn("hero_11", DataRegistry.Faction.PLAYER, Vector2i(3, 6))
	bul2.hp = 20; bul2.max_hp = 20; bul2.refresh_stats()
	var ally2 := spawn("hero_06", DataRegistry.Faction.PLAYER, Vector2i(4, 6))
	ally2.hp = 20; ally2.max_hp = 20; ally2.refresh_stats()
	var ally20 := ally2.hp
	var bul20 := bul2.hp
	ally2.take_damage(1, false, true)
	await sleep_frames(60)
	print("T2 伤害1不减免: 队友掉%d(应1) 塔盾掉%d(应0) => %s" % [ally20 - ally2.hp, bul20 - bul2.hp, "PASS" if (ally20 - ally2.hp) == 1 and (bul20 - bul2.hp) == 0 else "FAIL"])

	get_tree().quit()
