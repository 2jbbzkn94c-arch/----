extends Node
## 联机网络单例（NetBus）：主机/客户端连接 + 简单消息收发。
## 用底层 ENetMultiplayerPeer（put_packet/get_packet），与 NetBusVerify 已验证的方式一致，可单进程 headless 验证。
## 阶段3：先确保两台机器能连上、能双向发消息；后续用来驱动 Battle 指令。

signal host_started(display: String)      # 主机已开启
signal client_connected                  # 客户端已连上主机
signal packet_received(from_id: int, text: String)
signal connected                         # 与对端建立连接（CONNECTION_CONNECTED）
signal disconnected                      # 连接断开

var is_host := false
var is_online := false
var last_tick_error := ""
var active_port := -1   # 主机实际监听端口（自动避让被占用端口后的结果）

const DEFAULT_PORT := 18861
const HB_INTERVAL := 0.5      # 心跳发送间隔（秒）
const HB_TIMEOUT := 60.0      # 超过该时长未收到对端任何包 -> 判定对端离开。
# 放宽到 60s：手机退后台时主循环暂停、心跳发不出去，若仍用 3s 会被对端秒判掉线；
# 短暂回后台（切应用/锁屏）不至于断线，回前台立即补心跳恢复。

var _peer: ENetMultiplayerPeer = null
var _peers: Array[int] = []   # 已连接的对等方 id（主机侧记录客户端）
var _was_status := MultiplayerPeer.CONNECTION_DISCONNECTED   # 上一次连接状态（整数，检测连接建立/断开）
var _hb_acc := 0.0            # 心跳发送累加器
var _hb_text := "%shb" % char(1)   # 心跳包文本（带控制符前缀，与业务 JSON 区分）
var _last_recv_ms := 0        # 最近一次收到对端包的时间（Time.get_ticks_msec）；0=尚未收到过
var _peer_gone_emitted := false   # 已发出"对端离开"断线（防重复触发）

# 应用从后台回到前台：立即补发一次心跳（主循环暂停期间没发出去），并重置心跳累计，
# 让对端尽快刷新"仍在线"；避免 3s（现 60s）超时判掉。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and is_online and _peer_active():
		_hb_acc = 0.0
		send_all(_hb_text)

func _process(dt: float) -> void:
	if not is_online or _peer == null:
		return
	var st := _peer.get_connection_status()
	# 仅当实例仍活跃时 poll：连接失败/对端断开后 ENet 可能已销毁底层 host，
	# 此时再 poll 会报 "The multiplayer instance isn't currently active"。
	# 用状态先探测（不活跃时 get_connection_status 安全返回 DISCONNECTED），避免撞空。
	if st != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_peer.poll()
		st = _peer.get_connection_status()   # poll 后重读，检测连接建立/断开
	# 仅在"已连接 <-> 非已连接"边界发信号（CONNECTING 等中间态不当作断开）
	if st == MultiplayerPeer.CONNECTION_CONNECTED and _was_status != MultiplayerPeer.CONNECTION_CONNECTED:
		_was_status = MultiplayerPeer.CONNECTION_CONNECTED
		# 注意：服务器 create_server 后自己立即 CONNECTED，不代表对端已加入；
		# _last_recv_ms 保持 0（从未收到对端包），超时判定从"收到第一包"起才算。
		_peer_gone_emitted = false
		_hb_acc = 0.0
		connected.emit()
	elif st != MultiplayerPeer.CONNECTION_CONNECTED and _was_status == MultiplayerPeer.CONNECTION_CONNECTED:
		_was_status = st
		_peer_gone_emitted = true   # 底层已断开：不再走心跳判定
		disconnected.emit()
	if st == MultiplayerPeer.CONNECTION_CONNECTED:
		while _peer.get_available_packet_count() > 0:
			# 先取发送者 id 再取内容：get_packet() 会把该包弹出队列，
			# 若先取内容再 get_packet_peer()，最后一条包已被弹出 -> 队空报错。
			var from := _peer.get_packet_peer()
			var bytes := _peer.get_packet()
			if bytes.size() > 0:
				_last_recv_ms = Time.get_ticks_msec()   # 收到对端任何包 = 对端仍在线
				var text := bytes.get_string_from_utf8()
				if text == _hb_text:
					continue   # 心跳包：不转发给业务层
				packet_received.emit(from, text)
		# 心跳保活：连上后周期发心跳（让对端知道自己还活着）
		_hb_acc += dt
		if _hb_acc >= HB_INTERVAL:
			_hb_acc = 0.0
			send_all(_hb_text)
		# 对端失联判定：已连上且曾收到过包，但超过 HB_TIMEOUT 没任何包 -> 判定对方退出
		var now_ms := Time.get_ticks_msec()
		if _last_recv_ms > 0 and not _peer_gone_emitted and now_ms - _last_recv_ms > int(HB_TIMEOUT * 1000.0):
			_peer_gone_emitted = true
			disconnected.emit()   # 注意：不改 _was_status——ENet 自身状态未变，改了会触发"重新连接"误复位

# ---- 主机 ----
# 直接尝试 ENet 建服（安卓上额外的 PacketPeerUDP 探测可能误报失败，导致明明可开却说失败）。
# 端口被占用时 create_server 会返回错误，据此逐一向后试端口即可。
func host_match(port: int = DEFAULT_PORT) -> void:
	stop()
	var first_err := -1
	var tried := ""
	for i in 12:
		var p := port + i
		var cand := ENetMultiplayerPeer.new()
		var err := cand.create_server(p, 2)
		if err == OK:
			_peer = cand
			active_port = p
			is_host = true
			is_online = true
			host_started.emit("localhost:%d" % active_port)
			return
		if first_err < 0:
			first_err = err
		tried += ("%d, " % p)
	last_tick_error = "主机开启失败（端口 %s不可用，首次错误 %s）" % [tried, error_string(first_err) if first_err >= 0 else "未知"]
	push_error(last_tick_error)
	_peer = null

# ---- 客户端 ----
func join_match(address: String, port: int = DEFAULT_PORT) -> void:
	stop()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		last_tick_error = "连接失败: %s" % err
		push_error(last_tick_error)
		_peer = null
		return
	is_host = false
	is_online = true
	client_connected.emit()

# ---- 发送 ----
# 底层实例是否仍活跃（连接已建立且未被销毁）。断线/对端离开后 ENet 可能已不可用，
# 此时 get_connection_status 安全返回 DISCONNECTED，发送会撞 "instance isn't currently active"。
func _peer_active() -> bool:
	if not is_online or _peer == null:
		return false
	return _peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED

func send_to(peer_id: int, text: String) -> void:
	if not _peer_active():
		return
	# 目标对端还没真正连上（主机刚开、客户端还在握手）→ 直接跳过。
	# 否则 ENet 会报 "The multiplayer instance isn't currently connected to any server or client"。
	if not _peer_connected(peer_id):
		return
	_peer.set_target_peer(peer_id)
	_peer.put_packet(text.to_utf8_buffer())

func send_all(text: String) -> void:
	if not _peer_active() or not is_link_up():
		return   # 还没有可发的对象（主机无客户端 / 客户端仍在握手）：发了也是同样的错
	_peer.set_target_peer(MultiplayerPeer.TARGET_PEER_BROADCAST)
	_peer.put_packet(text.to_utf8_buffer())

# 本端与对端是否**真正**连上了（可安全收发的前提）：
#   主机：至少有一个客户端连进来（主机 create_server 后自身状态就是 CONNECTED，但不代表有人在）；
#   客户端：与主机的握手已完成（CONNECTED）。中间态 CONNECTING 时发包会撞 ENet 的 ERR_UNCONFIGURED。
func is_link_up() -> bool:
	if not _peer_active():
		return false
	if is_host:
		return _peer.get_peers().size() > 0
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

# 指定对端是否已连上（主机侧看它在不在 ENet 的已连接列表里；客户端侧只认 peer 1 = 主机）
func _peer_connected(peer_id: int) -> bool:
	if not _peer_active():
		return false
	if is_host:
		return _peer.get_peers().has(peer_id)
	return _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

# ---- 停止/断开 ----
func stop() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	is_online = false
	is_host = false
	active_port = -1
	_was_status = MultiplayerPeer.CONNECTION_DISCONNECTED   # 复位连接状态检测，避免下次 host/join 误判
	_peers.clear()
	_hb_acc = 0.0
	_last_recv_ms = 0
	_peer_gone_emitted = false
	last_tick_error = ""
