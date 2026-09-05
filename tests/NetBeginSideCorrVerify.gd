extends Node
## 模拟"两端 active_side 漂移"场景并校验 begin_side 校正：主机权威公布当前行动方，
## 客户端收到后强制同步 active_side，确保哪边该操作/哪边该等待一致（不会"我的回合，敌方可行动"）。
## 运行：godot --headless --scene res://tests/NetBeginSideCorrVerify.tscn
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

func _setup(b: Battle) -> void:
	GameState.clear_placement()
	b.set_random_seed(12345)
	GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
	GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
	b._place_units()
	b._preview_cells = {}
	b._apply_highlights()

func _which_can_act(b: Battle) -> bool:
	# 谁能操作 = state == PLAYER_INPUT（仅当前行动方在 _begin_side 中置位）
	return b.state == Battle.State.PLAYER_INPUT

func _run() -> void:
	GameState.is_online = true
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	host.grid.view_flip = false
	client.grid.view_flip = true
	var ok := true
	# 伪造漂移：主机认为当前是"玩家(SIDE_PLAYER)"回合，但客户端的 active_side 被错置成 SIDE_ENEMY（漂移）
	GameState.is_host = true
	GameState.active_side = GameState.SIDE_PLAYER
	host._begin_side(GameState.SIDE_PLAYER)   # 主机进入玩家回合
	# 客户端视角伪漂移：给客户端一个错误的 active_side
	GameState.is_host = false
	# 客户端本地应先进入"玩家回合"（它视角 my=ENEMY，非当前方 -> 等待/ENEMY_TURN）
	# 但若它漂移到 active_side=SIDE_ENEMY 且自己 begin_side，则误以为能操作
	client._begin_side(GameState.SIDE_PLAYER)   # 客户端(视角my=ENEMY)在玩家回合应"等待"
	if _which_can_act(client):
		ok = false
		print("  [漂移前] 客户端在玩家回合本应等待，却可操作: state=%d" % client.state)
	# 测试 begin_side 校正：主机广播"当前行动方=玩家"，客户端收到后 active_side 校正为玩家
	client._on_net_packet(1, JSON.stringify({ "type": "begin_side", "side": GameState.SIDE_PLAYER }))
	if client._my_side() != GameState.SIDE_ENEMY:
		ok = false
		print("  客户端 _my_side=%d(应SIDE_ENEMY)" % client._my_side())
	# 校验：玩家回合下，主机可操作(PLAYER_INPUT)、客户端不操作(ENEMY_TURN)
	if host.state != Battle.State.PLAYER_INPUT:
		ok = false
		print("  主机玩家回合 state=%d(应PLAYER_INPUT)" % host.state)
	if client.state == Battle.State.PLAYER_INPUT:
		ok = false
		print("  客户端玩家回合 state=%d(不应PLAYER_INPUT)" % client.state)
	print("  [校正后] 主机state=%d 客户端state=%d" % [host.state, client.state])
	# 敌方回合：主机等待、客户端可操作
	GameState.is_host = true
	host._begin_side(GameState.SIDE_ENEMY)   # 主机(视角my=PLAYER)在敌回合应等待
	GameState.is_host = false
	client._begin_side(GameState.SIDE_ENEMY)   # 客户端(视角my=ENEMY)在敌回合可操作
	if host.state == Battle.State.PLAYER_INPUT:
		ok = false
		print("  主机敌回合 state=%d(不应PLAYER_INPUT)" % host.state)
	if client.state != Battle.State.PLAYER_INPUT:
		ok = false
		print("  客户端敌回合 state=%d(应PLAYER_INPUT)" % client.state)
	print("  [敌回合] 主机state=%d 客户端state=%d" % [host.state, client.state])
	print("T1 begin_side校正+回合门控: => %s" % ["PASS" if ok else "FAIL"])
	GameState.is_online = false
	get_tree().quit()
