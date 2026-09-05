extends Node
## 校验"回合门控"不变量：active_side 为某一方时，只有该方(本端 _my_side)持有 state==PLAYER_INPUT，
## 另一端必须处于非输入态（ENEMY_TURN/ANIMATING 等），避免"我的回合，敌方可行动"。
## 双向：分别模拟 主机回合 / 客户端(敌方)回合，检查两端 state 正确。
## 运行：godot --headless --scene res://tests/NetTurnGateVerify.tscn
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
	# 不调 _start_match：直接测 _begin_side 的门控
	b._preview_cells = {}
	b._apply_highlights()

func _run() -> void:
	GameState.is_online = true
	clear_all(host); clear_all(client)
	_setup(host); _setup(client)
	host.grid.view_flip = false
	client.grid.view_flip = true
	var ok := true
	# 真实场景是独立进程：分别注入主机/客户端视角（否则共享 autoload 无法同时区分）
	# 主机视角：active_side=玩家先手
	GameState.is_host = true
	GameState.active_side = GameState.SIDE_PLAYER
	host._begin_side(GameState.SIDE_PLAYER)
	if host.state != Battle.State.PLAYER_INPUT:
		ok = false
		print("  [主机视角][玩家回合] 主机 state=%d(应PLAYER_INPUT)" % host.state)
	if host._my_side() != GameState.SIDE_PLAYER:
		ok = false
		print("  主机 _my_side=%d(应SIDE_PLAYER)" % host._my_side())
	print("  [主机视角][玩家回合] 主机state=%d" % host.state)
	# 主机视角：敌放回合 SIDE_ENEMY -> 主机应等待（非 PLAYER_INPUT）
	GameState.active_side = GameState.SIDE_ENEMY
	host._begin_side(GameState.SIDE_ENEMY)
	if host.state == Battle.State.PLAYER_INPUT:
		ok = false
		print("  [主机视角][敌回合] 主机 state=%d(不应PLAYER_INPUT)" % host.state)
	print("  [主机视角][敌回合] 主机state=%d" % host.state)
	# 客户端视角：is_host=false -> 客户端操作红方
	GameState.is_host = false
	GameState.active_side = GameState.SIDE_ENEMY
	client._begin_side(GameState.SIDE_ENEMY)
	if client.state != Battle.State.PLAYER_INPUT:
		ok = false
		print("  [客户端视角][敌回合] 客户端 state=%d(应PLAYER_INPUT)" % client.state)
	if client._my_side() != GameState.SIDE_ENEMY:
		ok = false
		print("  客户端 _my_side=%d(应SIDE_ENEMY)" % client._my_side())
	print("  [客户端视角][敌回合] 客户端state=%d" % client.state)
	# 客户端视角：玩家回合 SIDE_PLAYER -> 客户端应等待（非 PLAYER_INPUT）
	GameState.active_side = GameState.SIDE_PLAYER
	client._begin_side(GameState.SIDE_PLAYER)
	if client.state == Battle.State.PLAYER_INPUT:
		ok = false
		print("  [客户端视角][玩家回合] 客户端 state=%d(不应PLAYER_INPUT)" % client.state)
	print("  [客户端视角][玩家回合] 客户端state=%d" % client.state)
	print("T1 回合门控: => %s" % ["PASS" if ok else "FAIL"])
	GameState.is_online = false
	get_tree().quit()

