extends Node
## 联机敌轮部署双端一致：客户端 _try_place_enemy_deploy 放 enemy；主机收到 deploy 后 apply_deployment 放置。
## 验证两端 enemy 部署结果完全一致。
## 运行：godot --headless --scene res://tests/NetEnemyDeployVerify.tscn
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
	b.player_pool = []
	b.enemy_pool = []

func _setup(b: Battle) -> void:
	GameState.clear_placement()
	b.set_random_seed(12345)
	GameState.is_online = true

func _run() -> void:
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	# 客户端敌轮部署：设 pending + state，然后放 enemy (0,1)
	client._pending_enemy_deploy = "hero_13"
	client.state = Battle.State.PLACE_DEPLOY
	# 需 enemy 出生区含 (0,1) —— _in_spawn_cell(ENEMY)
	var ok := client._try_place_enemy_deploy(Vector2i(0, 1))
	# 主机收到 deploy(ENEMY)：手动 apply_deployment
	host.apply_deployment(DataRegistry.Faction.ENEMY, "hero_13", Vector2i(0, 1))
	host._deploy_after_pick()
	client._deploy_after_pick()

	var same := true
	var c_enemy = client.occupancy.get(Vector2i(0, 1), null)
	var h_enemy = host.occupancy.get(Vector2i(0, 1), null)
	if c_enemy == null or h_enemy == null or c_enemy.hero_id != h_enemy.hero_id:
		same = false
	print("T1 敌轮部署双端一致: client deployed=%d host deployed=%d 放置OK=%s => %s" % [
		client.enemy_deployed.size(), host.enemy_deployed.size(), str(ok),
		"PASS" if same and ok and client.enemy_deployed.size() == 1 and host.enemy_deployed.size() == 1 else "FAIL"])
	GameState.is_online = false
	get_tree().quit()
