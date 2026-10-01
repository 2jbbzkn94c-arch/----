extends Node
## 本地"思考面板"：引擎自己在 127.0.0.1 上开一个小 HTTP 服务，浏览器打开就能看我方 AI 的思考状态。
##
##   http://127.0.0.1:14330/        → 面板页面（每 1 秒拉一次下面的 JSON）
##   http://127.0.0.1:14330/state   → 当前快照 + 最近 40 手历史（JSON）
##
## 只绑 127.0.0.1（外部访问不到）、只读、无鉴权 —— 它只是把引擎内存里的快照吐出来，改不了任何东西。
## 引擎在主线程里同步搜 1.5 秒时页面会"卡一下"，属正常（`_process` 那会儿没跑）。

var _server := TCPServer.new()
var _port := 14330
var _html := ""
var _snap: Dictionary = {}      # 当前快照（最后一手决策）
var _history: Array = []        # 最近若干手（倒序展示）
var _clients: Array = []        # [{ "peer": StreamPeerTCP, "buf": PackedByteArray }]
var _log: Callable = Callable()


func start(port: int, log_cb: Callable) -> void:
	_port = port
	_log = log_cb
	_html = _read_html()
	var err := _server.listen(_port, "127.0.0.1")
	if err != OK:
		_call_log("!! 思考面板起不来（127.0.0.1:%d，err=%d）：换端口用 --watch-port=N" % [_port, err])
		return
	_call_log("思考面板：http://127.0.0.1:%d/ （浏览器打开就能看 AI 每一手在想什么）" % _port)
	set_process(true)


func push(snap: Dictionary) -> void:
	_snap = snap
	_history.push_front(snap)
	if _history.size() > 40:
		_history.resize(40)
	if _snap.has("history_head"):
		_snap.erase("history_head")


func _process(_delta: float) -> void:
	if not _server.is_connection_available():
		_pass_clients()
		return
	var peer := _server.take_connection()
	_clients.append({"peer": peer, "buf": PackedByteArray()})
	_pass_clients()


## 读请求 → 回包 → 关连接（极简 HTTP/1.1，够浏览器 fetch 用）
func _pass_clients() -> void:
	var keep: Array = []
	for c in _clients:
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		var st := peer.get_status()
		if st != StreamPeerTCP.STATUS_CONNECTED:
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			var got: Array = peer.get_partial_data(avail)
			if int(got[0]) == OK:
				c["buf"] = (c["buf"] as PackedByteArray) + (got[1] as PackedByteArray)
		var req := (c["buf"] as PackedByteArray).get_string_from_utf8()
		if req.find("\r\n\r\n") < 0:
			if req.length() > 8192:
				peer.disconnect_from_host()
				continue
			keep.append(c)
			continue
		var path := _path_of(req)
		_respond(peer, path)
		peer.disconnect_from_host()
	_clients = keep


func _path_of(req: String) -> String:
	var line := req.split("\r\n")[0] if req.find("\r\n") >= 0 else req
	var bits := line.split(" ")
	return bits[1] if bits.size() >= 2 else "/"


func _respond(peer: StreamPeerTCP, path: String) -> void:
	var body := ""
	var ctype := "text/html; charset=utf-8"
	if path.begins_with("/state"):
		body = JSON.stringify({"now": _snap, "history": _history})
		ctype = "application/json; charset=utf-8"
	elif path == "/" or path.begins_with("/index"):
		body = _html
	else:
		body = "not found"
		ctype = "text/plain; charset=utf-8"
	var bytes := body.to_utf8_buffer()
	var head := "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [ctype, bytes.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(bytes)


func _read_html() -> String:
	var p := "res://arena/思考面板.html"
	if not FileAccess.file_exists(p):
		return "<html><body style='font-family:sans-serif;background:#14161a;color:#ddd'><h3>找不到 res://arena/思考面板.html</h3><pre id='p'></pre><script>setInterval(async()=>{document.getElementById('p').textContent=JSON.stringify(await (await fetch('/state')).json(),null,1)},1000)</script></body></html>"
	var f := FileAccess.open(p, FileAccess.READ)
	var s := f.get_as_text() if f != null else ""
	return s


func _call_log(msg: String) -> void:
	if _log.is_valid():
		_log.call(msg)
