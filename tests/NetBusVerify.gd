extends Node
## ENet 双 peer 直连收发验证：一个 server peer + 一个 client peer，同一进程内连上并双向收发。
## 验证网络通道能通（最小联机骨架）；NetBus 单例后续再接 Battle。
## 运行：godot --headless --scene res://tests/NetBusVerify.tscn
var server: ENetMultiplayerPeer
var client: ENetMultiplayerPeer
var server_got := ""
var client_got := ""

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	server = ENetMultiplayerPeer.new()
	var se := server.create_server(18862, 2)
	print("T1 主机创建: err=%s => %s" % [se, "PASS" if se == OK else "FAIL"])

	client = ENetMultiplayerPeer.new()
	var ce := client.create_client("127.0.0.1", 18862)
	print("T2 客户端连接: err=%s => %s" % [ce, "PASS" if ce == OK else "FAIL"])

	# 等握手完成
	for i in 60:
		await get_tree().process_frame
		server.poll()
		client.poll()
		if server.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED and client.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break

	var sst := server.get_connection_status()
	var cst := client.get_connection_status()
	print("T3 双方握手: server=%s client=%s => %s" % [sst, cst, "PASS" if sst == MultiplayerPeer.CONNECTION_CONNECTED and cst == MultiplayerPeer.CONNECTION_CONNECTED else "FAIL"])

	# 客户端 -> 主机
	client.put_packet(PackedByteArray("hello-host".to_utf8_buffer()))
	for i in 30:
		await get_tree().process_frame
		server.poll()
		if server.get_available_packet_count() > 0:
			server_got = server.get_packet().get_string_from_utf8()
			break
	print("T4 客户端->主机: got='%s' => %s" % [server_got, "PASS" if server_got == "hello-host" else "FAIL"])

	# 主机 -> 客户端
	server.put_packet(PackedByteArray("hello-client".to_utf8_buffer()))
	for i in 30:
		await get_tree().process_frame
		client.poll()
		if client.get_available_packet_count() > 0:
			client_got = client.get_packet().get_string_from_utf8()
			break
	print("T5 主机->客户端: got='%s' => %s" % [client_got, "PASS" if client_got == "hello-client" else "FAIL"])

	server.close()
	client.close()
	get_tree().quit()
