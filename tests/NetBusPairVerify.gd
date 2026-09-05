extends Node
## NetBus 双实例互通验证：A=主机、B=客户端，底层 ENet 直连并双向收一条消息。
## 运行：godot --headless --scene res://tests/NetBusPairVerify.tscn

var host: Node   # 一个独立的 NetBus 节点实例（主机）
var cli: Node    # 另一个 NetBus 节点实例（客户端）
var host_got := ""
var cli_got := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	# 创建两个独立 NetBus 实例（import 后用 new）
	host = _make_net("host")
	cli = _make_net("cli")
	add_child(host)
	add_child(cli)

	# A 主机
	host.host_match(18863)
	print("T1 主机开启: online=%s host=%s => %s" % [host.is_online, host.is_host, "PASS" if host.is_online and host.is_host else "FAIL"])

	# B 客户端连上
	cli.join_match("127.0.0.1", 18863)
	print("T2 客户端连接: online=%s host=%s => %s" % [cli.is_online, cli.is_host, "PASS" if cli.is_online and not cli.is_host else "FAIL"])

	# 等双方都真连上（CONNECTION_CONNECTED = 2）
	for i in 90:
		await get_tree().process_frame
		var hc: int = host._peer.get_connection_status()
		var cc: int = cli._peer.get_connection_status()
		if hc == MultiplayerPeer.CONNECTION_CONNECTED and cc == MultiplayerPeer.CONNECTION_CONNECTED:
			break
	print("T2b 双方CONNECTED: host=%d cli=%d => %s" % [host._peer.get_connection_status(), cli._peer.get_connection_status(), "PASS" if host._peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and cli._peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED else "FAIL"])

	# B(client, peer id=1) 发给 主机(server)
	host.packet_received.connect(func(_f, t): host_got = t)
	cli.packet_received.connect(func(_f, t): cli_got = t)
	print("  [DBG] host连接状态=", host._peer.get_connection_status(), " cli连接状态=", cli._peer.get_connection_status())
	cli.send_to(1, "hi-host")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	print("  [DBG] host可用包=", host._peer.get_available_packet_count(), " cli可用包=", cli._peer.get_available_packet_count())
	print("T3 客户端->主机: host_got='%s' => %s" % [host_got, "PASS" if host_got == "hi-host" else "FAIL"])

	# 主机广播给客户端
	host.send_all("hi-client")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	print("T4 主机->客户端: cli_got='%s' => %s" % [cli_got, "PASS" if cli_got == "hi-client" else "FAIL"])

	host.stop()
	cli.stop()
	get_tree().quit()

# 用脚本类创建 NetBus 实例（NetBus extends Node，直接 new）
func _make_net(nm: String) -> Node:
	var s: Script = load("res://autoload/NetBus.gd")
	var n: Node = s.new()
	n.name = nm
	return n
