extends Node
## 联机回合制部署回环：主机点选/放置蓝方（PLAYER），客户端点选/放置红方（ENEMY），
## 通过 _on_net_packet 模拟双向收发，验证两端 卡池/已部署/棋盘占用/_deploy_side 每步一致，
## 最后双方同时进入开战（_begin_after_deploy，roster 一致）。
## 运行：godot --headless --scene res://tests/NetDeployRoundTripVerify.tscn
var host: Battle
var client: Battle
var step := 0

func _ready() -> void:
	host = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(host)
	client = load("res://scenes/Main.tscn").instantiate() as Battle
	add_child(client)
	_run.call_deferred()

func _clear(b: Battle) -> void:
	for u in b.units:
		if is_instance_valid(u):
			u.queue_free()
	b.units.clear()
	b.occupancy.clear()
	b.obstacles.clear()
	b.graves.clear()
	b.bombs.clear()
	b.player_dead = 0
	b.enemy_dead = 0
	b.player_deployed = []
	b.enemy_deployed = []
	b.player_pool = []
	b.enemy_pool = []
	b._pending_deploy = ""
	b._pending_enemy_deploy = ""
	b._deploy_side = 0

func _same(b1: Battle, b2: Battle) -> bool:
	if b1.units.size() != b2.units.size():
		print("  单位数不同: %d vs %d" % [b1.units.size(), b2.units.size()])
		return false
	for u in b1.units:
		var m = b2.occupancy.get(u.cell, null)
		if m == null:
			print("  对方缺单元格 %s" % str(u.cell))
			return false
		if m.hero_id != u.hero_id:
			print("  单元格 %s 英雄不同: %s vs %s" % [str(u.cell), u.hero_id, m.hero_id])
			return false
	if b1.player_deployed != b2.player_deployed:
		print("  player_deployed 不同: %s vs %s" % [str(b1.player_deployed), str(b2.player_deployed)])
		return false
	if b1.enemy_deployed != b2.enemy_deployed:
		print("  enemy_deployed 不同: %s vs %s" % [str(b1.enemy_deployed), str(b2.enemy_deployed)])
		return false
	if b1.player_pool != b2.player_pool:
		print("  player_pool 不同: %s vs %s" % [str(b1.player_pool), str(b2.player_pool)])
		return false
	if b1.enemy_pool != b2.enemy_pool:
		print("  enemy_pool 不同: %s vs %s" % [str(b1.enemy_pool), str(b2.enemy_pool)])
		return false
	if b1._deploy_side != b2._deploy_side:
		print("  _deploy_side 不同: %d vs %d" % [b1._deploy_side, b2._deploy_side])
		return false
	return true

func _run() -> void:
	GameState.clear_placement()
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
	GameState.is_online = true
	_clear(host); _clear(client)
	host.set_random_seed(12345)
	client.set_random_seed(12345)
	host._place_obstacles()
	client._place_obstacles()
	host._begin_deployment()
	client._begin_deployment()
	var ok := true
	step = 0
	var guard := 0
	while host.player_deployed.size() < 3 or host.enemy_deployed.size() < 3:
		guard += 1
		if guard > 20:
			ok = false
			print("  死循环保护：部署未完成")
			break
		if host._deploy_side == 0:
			# 玩家轮：主机点选+放置
			GameState.is_host = true
			var hid: String = host.player_pool[0]
			host._on_deploy_pick(hid)
			var cell := host._free_spawn_cell(DataRegistry.Faction.PLAYER)
			var placed := host._try_place_deploy(cell)
			# 模拟主机广播 -> 客户端 _on_net_packet
			client._on_net_packet(1, JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.PLAYER, "hero": hid, "cell": [cell.x, cell.y] }))
			if not placed:
				ok = false
				print("  [%d] 主机放置失败" % step)
		else:
			# 敌轮：客户端点选+放置
			GameState.is_host = false
			var hid2: String = client.enemy_pool[0]
			client._on_enemy_deploy_pick(hid2)
			var cell2 := client._free_spawn_cell(DataRegistry.Faction.ENEMY)
			var placed2 := client._try_place_enemy_deploy(cell2)
			# 模拟客户端广播 -> 主机 _on_net_packet
			host._on_net_packet(1, JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.ENEMY, "hero": hid2, "cell": [cell2.x, cell2.y] }))
			if not placed2:
				ok = false
				print("  [%d] 客户端放置失败" % step)
		step += 1
		if not _same(host, client):
			ok = false
			print("  [%d] 第 %d 步后双端不一致" % [step, step])
			break
	# 最后检查开战状态：roster 一致（_begin_after_deploy 已跑），部署计数对称完成
	var roster_ok := host.player_roster == client.player_roster and host.enemy_roster == client.enemy_roster
	print("T1 轮流部署回环: 步数=%d 玩家侧=%d 敌侧=%d 双端一致=%s roster一致=%s => %s" % [
		step, host.player_deployed.size(), host.enemy_deployed.size(), str(ok),
		str(roster_ok), "PASS" if ok and roster_ok and host.player_deployed.size() == 3 and host.enemy_deployed.size() == 3 else "FAIL"])
	GameState.is_online = false
	get_tree().quit()
