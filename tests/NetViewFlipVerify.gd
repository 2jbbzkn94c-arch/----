extends Node
## 验证"双方自己的英雄都显示在下方"的完整链路：
## 1) 主机(不翻转)与访客(翻转)共享同一套逻辑格/阵营 —— 部署后两端 units/占用完全一致；
## 2) 访客端在"敌轮"放置的 ENEMY 英雄，其屏幕位置应在棋盘底部区域；
## 3) 访客端对已翻转部署单位做"点击命中回查"，能精确还原其逻辑格（鼠标路径一致）。
## 运行：godot --headless --scene res://tests/NetViewFlipVerify.tscn
var host: Battle
var client: Battle

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

func _run() -> void:
	GameState.is_online = true
	GameState.is_host = true
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
	_clear(host); _clear(client)
	# 生产中主机/客户端是两个独立进程，各自 GameState.is_host 不同 -> 访客端 _ready 已开翻转。
	# 本测试共享同一个 GameState，故显式设置访客端翻转（等价于真实客户端进程）。
	client.grid.view_flip = true
	host.set_random_seed(12345)
	client.set_random_seed(12345)
	host._place_obstacles()
	client._place_obstacles()
	host._begin_deployment()
	client._begin_deployment()
	var ok := true
	# 访客端配置了翻转
	if not client.grid.view_flip:
		ok = false
		print("  访客端未开翻转")
	# 逐一在两端放置：玩家轮主机放 PLAYER，敌轮客户端放 ENEMY，经 _on_net_packet 同步
	var guard := 0
	while host.player_deployed.size() < 3 or host.enemy_deployed.size() < 3:
		guard += 1
		if guard > 20:
			ok = false
			print("  部署死循环")
			break
		if host._deploy_side == 0:
			GameState.is_host = true
			var hid: String = host.player_pool[0]
			host._on_deploy_pick(hid)
			var cell := host._free_spawn_cell(DataRegistry.Faction.PLAYER)
			host._try_place_deploy(cell)
			client._on_net_packet(1, JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.PLAYER, "hero": hid, "cell": [cell.x, cell.y] }))
		else:
			GameState.is_host = false
			var hid2: String = client.enemy_pool[0]
			client._on_enemy_deploy_pick(hid2)
			var cell2 := client._free_spawn_cell(DataRegistry.Faction.ENEMY)
			client._try_place_enemy_deploy(cell2)
			host._on_net_packet(1, JSON.stringify({ "type": "deploy", "faction": DataRegistry.Faction.ENEMY, "hero": hid2, "cell": [cell2.x, cell2.y] }))
	# 1) 两端单位/占用一致
	var same := host.units.size() == client.units.size()
	for u in host.units:
		if not same:
			break
		var m = client.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id:
			same = false
			break
	if not same:
		ok = false
		print("  两端单位/占用不一致")
	# 2)+3) 访客端：每个 ENEMY 单位，其屏幕位置应在棋盘中心下方，且鼠标回查 = 其逻辑格
	var origin := client.board_view.board_origin
	var center_y := origin.y + client.grid.flip_center().y
	for u in client.units:
		if u.faction != DataRegistry.Faction.ENEMY:
			continue
		# 屏幕位置
		var scr := u.position
		if scr.y <= center_y:
			ok = false
			print("  ENEMY 单位 %s 屏幕位置在中心上方: y=%f center_y=%f" % [u.hero_id, scr.y, center_y])
		# 鼠标回查：从屏幕位置反查格 = u.cell
		var hit := client.grid.world_to_cell(scr - origin)
		if hit != u.cell:
			ok = false
			print("  ENEMY 单位 %s 点击回查 %s != %s" % [u.hero_id, str(hit), str(u.cell)])
	print("T1 双方视角翻转: 两端一致=%s 访客ENEMY在下方=%s => %s" % [str(same), str(ok), "PASS" if ok and same else "FAIL"])
	GameState.is_online = false
	get_tree().quit()
