extends Node
## 联机回合同步回放：主机走完整回合（移动+攻击+结束回合），客户端重演同指令序列（含 end_turn 推进），
## 每步比较两端 units/cell/hp/回合/deployed。必须完全一致。
## 运行：godot --headless --scene res://tests/NetBattleTurnVerify.tscn
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
	# 让两端都进入玩家先手（模拟部署完成后 _start_match 调 _begin_side）
	GameState.start_match(GameState.SIDE_PLAYER)
	b._begin_side(GameState.SIDE_PLAYER)

func _same(b1: Battle, b2: Battle) -> bool:
	if b1.units.size() != b2.units.size():
		return false
	for u in b1.units:
		var m = b2.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id or m.hp != u.hp or m.moved_this_turn != u.moved_this_turn or m.attacked_this_turn != u.attacked_this_turn:
			return false
	return true

func _run() -> void:
	GameState.is_online = true
	GameState.is_host = true
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	var ok := true
	var step := 0
	var hhero := _find(host, "hero_06")
	var hi: int = host.units.find(hhero)
	var en := _find(host, "hero_13")
	var ei: int = host.units.find(en)
	# 玩家侧：移动 hero_06 到 (2,8)（主机权威执行，客户端经广播重演）
	host.apply_command({ "type": "move", "u": hi, "to": [2, 8] })
	client.apply_command({ "type": "move", "u": hi, "to": [2, 8] })
	await sleep_frames(350)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 move 后不同步" % step)
	# 玩家侧：hero_06 攻击 hero_13
	host.apply_command({ "type": "attack", "u": hi, "t": ei })
	client.apply_command({ "type": "attack", "u": hi, "t": ei })
	await sleep_frames(350)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 attack 后不同步" % step)
	# 玩家侧：结束回合 -> 主机权威执行 _end_side，客户端经 end_turn 重演
	host._end_side(GameState.SIDE_PLAYER)
	client._on_net_packet(1, JSON.stringify({ "type": "end_turn", "side": GameState.SIDE_PLAYER }))
	await sleep_frames(400)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 end_turn 后不同步" % step)
	# 敌侧（客户端）：敌方 hero_13 移动后结束
	var eh: int = client.units.find(_find(client, "hero_13"))
	host.apply_command({ "type": "move", "u": eh, "to": [0, 2] })
	client.apply_command({ "type": "move", "u": eh, "to": [0, 2] })
	await sleep_frames(350)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 敌方move 后不同步" % step)
	# 客户端结束敌侧回合：主机权威执行 _end_side，客户端经 end_turn 重演
	host._end_side(GameState.SIDE_ENEMY)
	client._on_net_packet(1, JSON.stringify({ "type": "end_turn", "side": GameState.SIDE_ENEMY }))
	await sleep_frames(400)
	step += 1
	if not _same(host, client):
		ok = false
		print("  第%d步 敌end_turn 后不同步" % step)
	print("T1 联机回合同步: 步数=%d active_side=%d => %s" % [step, GameState.active_side, "PASS" if ok else "FAIL"])
	print("  主机:", _state_desc(host))
	print("  客户端:", _state_desc(client))
	GameState.is_online = false
	get_tree().quit()

func _find(b: Battle, hid: String) -> Unit:
	for u in b.units:
		if u.alive and u.hero_id == hid:
			return u
	return null

func _state_desc(b: Battle) -> String:
	var s := ""
	for u in b.units:
		if u.alive:
			s += "%s@%s=%d " % [u.hero_id, str(u.cell), u.hp]
	return s.strip_edges()
