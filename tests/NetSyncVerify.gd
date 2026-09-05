extends Node
## 主机广播重演一致性验证：同种子 + 同一条指令，主机与客户端各自 apply_command 结果完全一致。
## 运行：godot --headless --scene res://tests/NetSyncVerify.tscn
var host: Battle
var client: Battle

func _ready() -> void:
	host = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(host)
	client = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(client)
	_run.call_deferred()

func seed_battle(b: Battle, s: int) -> void:
	b.set_random_seed(s)

func clear_all(b: Battle) -> void:
	for u in b.units:
		if is_instance_valid(u):
			u.queue_free()
	b.units.clear()
	b.occupancy.clear()
	b.bombs.clear()
	b.buff_items.clear()
	b.obstacles.clear()
	b.graves.clear()
	b.player_dead = 0
	b.enemy_dead = 0
	b.selected = null
	b.state = Battle.State.PLAYER_INPUT

func spawn(b: Battle, hid: String, f: int, c: Vector2i) -> Unit:
	return b._spawn_unit(hid, f, c)

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _run() -> void:
	# 双方同种子、同初始局势
	seed_battle(host, 42)
	seed_battle(client, 42)
	clear_all(host)
	clear_all(client)
	var hp := spawn(host, "hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var he := spawn(host, "hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	var cp := spawn(client, "hero_06", DataRegistry.Faction.PLAYER, Vector2i(3, 8))
	var ce := spawn(client, "hero_13", DataRegistry.Faction.ENEMY, Vector2i(4, 8))
	var hpi := host.units.find(hp)
	var hei := host.units.find(he)
	var cpi := client.units.find(cp)
	var cei := client.units.find(ce)
	he.hp = 20; he.max_hp = 20; he.refresh_stats()
	ce.hp = 20; ce.max_hp = 20; ce.refresh_stats()
	host._sync_ranged_adjacent()
	client._sync_ranged_adjacent()

	# 主机：execute move then attack；客户端：重演同两条指令
	host.apply_command({ "type": "move", "u": hpi, "to": [3, 7] })
	await sleep_frames(300)
	client.apply_command({ "type": "move", "u": cpi, "to": [3, 7] })
	await sleep_frames(300)
	host.apply_command({ "type": "attack", "u": hpi, "t": hei })
	await sleep_frames(300)
	client.apply_command({ "type": "attack", "u": cpi, "t": cei })
	await sleep_frames(300)

	var same := hp.cell == cp.cell and he.hp == ce.hp
	print("T1 主机-客户端结果一致: move cell=%s/%s 敌血=%d/%d => %s" % [
		str(hp.cell), str(cp.cell), he.hp, ce.hp, "PASS" if same else "FAIL"])

	get_tree().quit()
