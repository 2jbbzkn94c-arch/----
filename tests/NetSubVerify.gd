extends Node
## 联机替补回环：客户端（红方/ENEMY）阵亡一名，客户端手动选替补并落位，
## 经 sub 网令同步给主机；两端重演 _place_sub，验证单位/替补席/墓碑完全一致。
## 运行：godot --headless --scene res://tests/NetSubVerify.tscn
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
	b.player_roster = []
	b.enemy_roster = []
	b.selected = null

func sleep_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _find(b: Battle, hid: String) -> Unit:
	for u in b.units:
		if u.alive and u.hero_id == hid:
			return u
	return null

func _same(b1: Battle, b2: Battle) -> bool:
	if b1.units.size() != b2.units.size():
		print("  单位数不同: %d vs %d" % [b1.units.size(), b2.units.size()])
		return false
	for u in b1.units:
		var m = b2.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id or m.hp != u.hp:
			print("  单位不同步 %s@%s" % [u.hero_id, str(u.cell)])
			return false
	if b1.player_roster != b2.player_roster:
		print("  player_roster 不同: %s vs %s" % [str(b1.player_roster), str(b2.player_roster)])
		return false
	if b1.enemy_roster != b2.enemy_roster:
		print("  enemy_roster 不同: %s vs %s" % [str(b1.enemy_roster), str(b2.enemy_roster)])
		return false
	if b1.graves != b2.graves:
		print("  graves 不同")
		return false
	return true

func _run() -> void:
	GameState.clear_placement()
	# 用 5 张卡：前3上阵，余2进替补席
	GameState.player_deck = ["hero_06", "hero_17", "hero_26", "hero_30", "hero_11"]
	GameState.enemy_deck = ["hero_13", "hero_12", "hero_23", "hero_08", "hero_24"]
	GameState.is_online = true
	clear_all(host); clear_all(client)
	host.set_random_seed(12345)
	client.set_random_seed(12345)
	# 布置：两端上阵拆分（前3上阵进 units，其余进 roster）
	host._place_units()
	client._place_units()
	# 进入对战态：让"客户端的敌方/红方(ENEMY)"是当前行动方，客户端有人机视角
	GameState.is_host = false
	GameState.active_side = GameState.SIDE_ENEMY
	host.state = Battle.State.ENEMY_TURN
	client.state = Battle.State.ENEMY_TURN
	# 杀掉客户端(红方 ENEMY)一名 hero_13：两端重演同一阵亡（确定性）
	var ue = _find(client, "hero_13")
	var uh = _find(host, "hero_13")
	if ue == null or uh == null:
		print("  ! 未找到待杀单位")
		GameState.is_online = false
		get_tree().quit()
		return
	# 两端各自触发阵亡（同一命令重演）
	client._on_unit_died(ue, true)
	host._on_unit_died(uh, true)
	await sleep_frames(30)
	var ok := true
	# 客户端应已进入替补选人（_sub_faction=ENEMY）
	if client._sub_faction != DataRegistry.Faction.ENEMY:
		ok = false
		print("  客户端未进入敌替补: _sub_faction=%d state=%d" % [client._sub_faction, client.state])
	# 客户端选替补并落位 -> 发 sub 给主机
	var pick: String = client.enemy_roster[0]
	client._on_sub_pick(pick)
	var cell := client._free_spawn_cell(DataRegistry.Faction.ENEMY)
	var placed := client._try_place_sub(cell)
	# 客户端是发送方（_try_place_sub 里 send_to(1)），主机收到 -> _place_sub + 广播
	# 模拟主机网络收到（主机 _on_net_packet -> _place_sub + send_all）
	var submsg := JSON.stringify({ "type": "sub", "faction": DataRegistry.Faction.ENEMY, "hero": pick, "cell": [cell.x, cell.y] })
	host._on_net_packet(1, submsg)
	await sleep_frames(30)
	# 客户端收到主机广播重演
	client._on_net_packet(1, submsg)
	await sleep_frames(30)
	if not placed:
		ok = false
		print("  客户端落位失败")
	if not _same(host, client):
		ok = false
		print("  双端不同步")
	# --- 第二段：主机(蓝方 PLAYER)阵亡，主机手动选替补并落位，客户端重演 ---
	GameState.is_host = true
	GameState.active_side = GameState.SIDE_PLAYER
	var up = _find(host, "hero_06")
	if up == null or host.player_roster.size() == 0:
		print("  第二段：无 PLAYER 单位/替补  (units=%d roster=%d)" % [host.units.size(), host.player_roster.size()])
	else:
		host._on_unit_died(_find(host, "hero_06"), true)
		client._on_unit_died(_find(client, "hero_06"), true)
		await sleep_frames(30)
		print("  第二段 死后: host_units=%d client_units=%d host_sub=%d client_sub=%d" % [host.units.size(), client.units.size(), host._sub_faction, client._sub_faction])
		if host._sub_faction != DataRegistry.Faction.PLAYER:
			ok = false
			print("  主机未进入玩家替补: _sub_faction=%d state=%d" % [host._sub_faction, host.state])
		var pick2: String = host.player_roster[0]
		host._on_sub_pick(pick2)
		var cell2 := host._free_spawn_cell(DataRegistry.Faction.PLAYER)
		var placed2 := host._try_place_sub(cell2)
		print("  第二段 主机落位: placed=%s cell=%s" % [str(placed2), str(cell2)])
		# 主机 _try_place_sub -> _place_sub + send_all 广播；客户端收到重演
		var submsg2 := JSON.stringify({ "type": "sub", "faction": DataRegistry.Faction.PLAYER, "hero": pick2, "cell": [cell2.x, cell2.y] })
		client._on_net_packet(1, submsg2)
		await sleep_frames(30)
		print("  第二段 落位后: host_units=%d client_units=%d" % [host.units.size(), client.units.size()])
		if not placed2 or not _same(host, client):
			ok = false
			print("  第二段主机替补后不同步")
	print("T1 联机替补回环: 客户端落位=%s 双端一致=%s => %s" % [str(placed), str(ok), "PASS" if ok and placed else "FAIL"])
	print("  主机enemy_roster=%s 客户端enemy_roster=%s" % [str(host.enemy_roster), str(client.enemy_roster)])
	GameState.is_online = false
	get_tree().quit()
