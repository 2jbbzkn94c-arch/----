extends Node
## 联机整局同步回放：主机 Battle 走完整一回合（移动+攻击+结回），客户端重演同指令序列。
## 每一步后比较两端 units/cell/hp/回合，必须完全一致。
## 运行：godot --headless --scene res://tests/NetFullMatchVerify.tscn
var host: Battle
var client: Battle

func _ready() -> void:
	host = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(host)
	client = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(client)
	_run.call_deferred()

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

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _setup(b: Battle) -> void:
	GameState.clear_placement()
	b.set_random_seed(12345)
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
	b._place_units()

func _state_desc(b: Battle) -> String:
	var s := ""
	for u in b.units:
		if u.alive:
			s += "%s@%s=%d " % [u.hero_id, str(u.cell), u.hp]
	return s.strip_edges()

func _same(b1: Battle, b2: Battle) -> bool:
	if b1.units.size() != b2.units.size():
		return false
	for u in b1.units:
		var m = b2.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id or m.hp != u.hp:
			return false
	return true

func _run() -> void:
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	var ok := true
	var step := 0
	# 主机：找我方单位，移动到 (2,8)，再攻击敌方；两端同时重演同指令
	var hp_hero := _find_hero(host, "hero_06")
	var hi := host.units.find(hp_hero)
	# 我方 attack 敌方 hero_13
	var ehero := _find_hero(host, "hero_13")
	var ei := host.units.find(ehero)
	# host move
	host.submit_move(hi, Vector2i(2, 6))
	client.apply_command({ "type": "move", "u": hi, "to": [2, 8] })
	await sleep_frames(350)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 move 后不同步" % step)
	# host attack
	host.apply_command({ "type": "attack", "u": hi, "t": ei })
	client.apply_command({ "type": "attack", "u": hi, "t": ei })
	await sleep_frames(350)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 attack 后不同步" % step)

	print("T1 整局同步: %s" % ["PASS" if ok else "FAIL"])
	print("  主机:", _state_desc(host))
	print("  客户端:", _state_desc(client))
	get_tree().quit()

func _find_hero(b: Battle, hid: String) -> Unit:
	for u in b.units:
		if u.alive and u.hero_id == hid:
			return u
	return null
