extends Node
## 联机双端确定性验证：同种子下主机/客户端 Battle 各自 _place_units，单位位置/障碍/卡组应完全一致。
## 运行：godot --headless --scene res://tests/NetDeploySyncVerify.tscn
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

func _setup_online(b: Battle, deck_p: Array, deck_e: Array) -> void:
	# 模拟联机开局状态
	GameState.clear_placement()
	b.set_random_seed(12345)
	GameState.is_online = true
	GameState.player_deck = deck_p.duplicate()
	GameState.enemy_deck = deck_e.duplicate()
	# 手动放置（像联机 _ready 那样）
	b._place_units()

func _run() -> void:
	# 双方同卡组同种子
	var pdeck := ["hero_06", "hero_17", "hero_26"]
	var edeck := ["hero_13", "hero_12", "hero_23"]
	clear_all(host)
	clear_all(client)
	_setup_online(host, pdeck, edeck)
	_setup_online(client, pdeck, edeck)

	# 比较单位位置/阵营
	var same_cells := true
	for u in host.units:
		var m = client.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id or m.faction != u.faction:
			same_cells = false
			print("  不一致: 主机 %s@%s 客户端无/不同" % [u.hero_id, str(u.cell)])
	print("T1 单位位置/阵营一致: 主机units=%d => %s" % [host.units.size(), "PASS" if same_cells else "FAIL"])

	# 比较障碍
	var same_obs := host.obstacles.keys() == client.obstacles.keys()
	print("T2 障碍一致: => %s" % ["PASS" if same_obs else "FAIL"])

	print("  主机单位:", _units_desc(host))
	print("  客户端单位:", _units_desc(client))

	get_tree().quit()

func _units_desc(b: Battle) -> String:
	var s := ""
	for u in b.units:
		if u.alive:
			s += u.hero_id + "@" + str(u.cell) + " "
	return s.strip_edges()
