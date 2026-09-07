extends Node
## 联机部署双端一致：同种子两端 Battle，各自 apply_deployment 放同一批单位，验证位置/阵营完全一致。
## 运行：godot --headless --scene res://tests/NetDeploySync2Verify.tscn
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

func _setup(b: Battle) -> void:
	GameState.clear_placement()
	b.set_random_seed(12345)

func _run() -> void:
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	# 双方用同一批部署消息放置（玩家方 3 名 + 敌方 3 名）
	var deploy_plan := [
		{ "faction": DataRegistry.Faction.PLAYER, "hero": "hero_06", "cell": Vector2i(1, 6) },
		{ "faction": DataRegistry.Faction.PLAYER, "hero": "hero_17", "cell": Vector2i(3, 6) },
		{ "faction": DataRegistry.Faction.PLAYER, "hero": "hero_26", "cell": Vector2i(5, 6) },
		{ "faction": DataRegistry.Faction.ENEMY, "hero": "hero_13", "cell": Vector2i(0, 1) },
		{ "faction": DataRegistry.Faction.ENEMY, "hero": "hero_12", "cell": Vector2i(6, 1) },
		{ "faction": DataRegistry.Faction.ENEMY, "hero": "hero_23", "cell": Vector2i(3, 0) },
	]
	for d in deploy_plan:
		host.apply_deployment(d.faction, d.hero, d.cell)
		client.apply_deployment(d.faction, d.hero, d.cell)

	var same := true
	for u in host.units:
		var m = client.occupancy.get(u.cell, null)
		if m == null or m.hero_id != u.hero_id or m.faction != u.faction:
			same = false
			print("  不一致:", u.hero_id, "@", u.cell)
	print("T1 部署双端一致: 主机=%d 客户端=%d => %s" % [host.units.size(), client.units.size(), "PASS" if same and host.units.size() == 6 else "FAIL"])
	get_tree().quit()
