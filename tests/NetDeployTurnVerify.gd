extends Node
## 联机轮流部署推进：两端同种子，按先后轮交替各 deploy 1 个，每步两端同步放置并校验部署计数/位置一致。
## 运行：godot --headless --scene res://tests/NetDeployTurnVerify.tscn
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
	b.obstacles.clear()
	b.graves.clear()
	b.player_dead = 0
	b.enemy_dead = 0
	b.player_deployed = []
	b.enemy_deployed = []

func _setup(b: Battle) -> void:
	GameState.clear_placement()
	b.set_random_seed(12345)

func _same(b1: Battle, b2: Battle) -> bool:
	if b1.units.size() != b2.units.size():
		return false
	for u in b1.units:
		var m = b2.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id:
			return false
	# 部署计数也须一致
	if b1.player_deployed.size() != b2.player_deployed.size() or b1.enemy_deployed.size() != b2.enemy_deployed.size():
		return false
	return true

func _run() -> void:
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	# 双方各 3 个担任首发（交替一对一对：先玩家侧1个、再敌侧1个）
	var p_plan := [["hero_06", Vector2i(1, 8)], ["hero_17", Vector2i(3, 8)], ["hero_26", Vector2i(5, 8)]]
	var e_plan := [["hero_13", Vector2i(0, 1)], ["hero_12", Vector2i(6, 1)], ["hero_23", Vector2i(3, 0)]]
	var ok := true
	for i in 3:
		# 玩家侧这轮放第 i 个
		host.apply_deployment(DataRegistry.Faction.PLAYER, p_plan[i][0], p_plan[i][1])
		client.apply_deployment(DataRegistry.Faction.PLAYER, p_plan[i][0], p_plan[i][1])
		# 敌侧这轮放第 i 个
		host.apply_deployment(DataRegistry.Faction.ENEMY, e_plan[i][0], e_plan[i][1])
		client.apply_deployment(DataRegistry.Faction.ENEMY, e_plan[i][0], e_plan[i][1])
		if not _same(host, client):
			ok = false
			print("  第%d轮后不同步" % (i + 1))
	print("T1 轮流部署推进一致: 主机(pl=%d,en=%d) 客户端(pl=%d,en=%d) => %s" % [
		host.player_deployed.size(), host.enemy_deployed.size(),
		client.player_deployed.size(), client.enemy_deployed.size(),
		"PASS" if ok else "FAIL"])
	get_tree().quit()
