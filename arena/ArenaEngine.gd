extends Node
## 竞技场外部引擎客户端（协议见 https://tb.qiaohome.top:3333/api/arena/v1/docs）。
##
## 干什么：常驻进程 → 长轮询 `POST /tasks/next` 领自己的决策 → 用项目自己的 AI 选一个
## `legalActions[].actionId` 提交 → 领下一个。收到 `match_end` 就 ACK 并清本局缓存。
##
## 怎么起（推荐走 RL\train\跑Godot隔离.ps1 包装，见 arena\跑引擎.ps1）：
##   godot --headless --path <项目根> --scene res://arena/ArenaEngine.tscn -- --token=XXX
##
## 参数（命令行 `--` 之后，或同名环境变量）：
##   --url=<基址>      ARENA_URL       默认 https://tb.qiaohome.top:3333/api/arena/v1
##   --token=<令牌>    ARENA_TOKEN     【必填】网页「接入引擎」登记后一次性显示的令牌
##   --tier=<1..7>     ARENA_TIER      AI 难度档（默认 3），见 ArenaBridge
##   --think=<毫秒>    ARENA_THINK_MS  单次搜索上限。**默认 0 = 自动**：按本局选的回合预算算 ——
##   --once            ARENA_ONCE=1    收到并确认一场结束通知后退出
##   --max-tasks=<N>                   最多处理 N 个决策任务后退出（冒烟用）
##   --insecure                        允许自签/不受信 TLS 证书（默认关；连不上证书错时用）
##                                     每手最多分预算的 1/3、并用单机噩梦档的 40 秒封顶
##                                     （60 秒局 ⇒ 20 秒/手；120 秒局 ⇒ 满 40 秒，与单机同量级）
##   --quiet                           只打关键行（不打印每次决策明细）
##
## 输出：每行以 `ARENA|` 开头，方便重定向到文件里 grep。

const DEFAULT_URL := "https://tb.qiaohome.top:3333/api/arena/v1"
const PROTOCOL_VERSION := "1"
const POLL_WAIT_MS := 25000
const POLL_HTTP_TIMEOUT_S := 35.0
const CMD_HTTP_TIMEOUT_S := 20.0
const BACKOFF_S := [0.5, 1.0, 2.0, 4.0, 5.0]
const LOG_PREFIX := "ARENA|"

# ---- 运行配置（_ready 里解析）----
var _base := DEFAULT_URL
var _token := ""
var _tier := 3
var _think_ms := 0        # 0 = 自动（按本局回合预算算，见 ArenaBridge._think_budget）
var _once := false
var _max_tasks := 0
var _insecure := false
var _quiet := false
var _policy := "ai"     # ai | random（random 只用来验证连通性）
var _no_cache := true     # 计划缓存：**默认关** = 每一手都重新搜（用户 2026-10-01 口径：AI 每一手都得真花几秒想）。
                          # `--cache-plan` 切回旧口径（一回合只搜一次、后面几手照计划执行，几十毫秒）。
## 搜索宽度覆盖（`--beam=N`）：0 = 用权重文件里的（噩梦档 400）。
var _beam := 0
## 每手最少思考毫秒（`--min-think=N`）：搜索收敛太快时把本手垫到这个时长，让节奏像游戏里。
## 默认 2000ms；`--min-think=0` 关掉（纯拼手速）。
var _min_think := 2000
var _aggro := true        # --no-aggro：关掉"敢压上"的擂台倾向（回权重文件原值）
var _watch = null         # ArenaWatch：本地"思考面板"
var _watch_on := true
var _watch_port := 14330

# ---- 运行态 ----
var _bridge = null            # ArenaBridge：观察 → 内部局面 → 动作
var _rules: Dictionary = {}   # 当前规则包（heroes / board）
var _rules_version := ""
var _rules_available: Array = []   # /rules 给出的"服务器当前可开赛版本"（兼容性自检用）
var _engine: Dictionary = {}
var _stop := false
var _task_count := 0
var _ack_pending := {}        # matchId -> true（同一局只打印一次结果）


func _ready() -> void:
	_write_pid()
	_parse_args()
	if _token == "":
		_log("!! 没给令牌：用 --token=XXX 或环境变量 ARENA_TOKEN")
		get_tree().quit(2)
		return
	_log("启动：url=%s tier=%d think=%s policy=%s once=%s" % [_base, _tier, ("自动（按本局回合预算）" if _think_ms <= 0 else "%dms" % _think_ms), _policy, str(_once)])
	_main.call_deferred()


## 把自己的 PID 写到 `arena/引擎.pid`：要停引擎时**只停这一个 PID**，
## 绝不能再用"按进程名杀所有 Godot" —— 那条会把用户自己起的 headless Godot（探针/跑批/检视）一起杀掉。
func _write_pid() -> void:
	var dir := ProjectSettings.globalize_path("res://arena")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("%s/引擎.pid" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(str(OS.get_process_id()))
		f.close()


func _parse_args() -> void:
	_base = _env_or("ARENA_URL", _base)
	_token = _env_or("ARENA_TOKEN", "")
	_tier = int(_env_or("ARENA_TIER", "3"))
	_think_ms = int(_env_or("ARENA_THINK_MS", "0"))
	_policy = _env_or("ARENA_POLICY", "ai")
	_once = _env_or("ARENA_ONCE", "") == "1"
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--url="):
			_base = s.substr(6)
		elif s.begins_with("--token="):
			_token = s.substr(8)
		elif s.begins_with("--tier="):
			_tier = int(s.substr(7))
		elif s.begins_with("--think="):
			_think_ms = int(s.substr(8))
		elif s.begins_with("--policy="):
			_policy = s.substr(9)
		elif s.begins_with("--max-tasks="):
			_max_tasks = int(s.substr(12))
		elif s == "--once":
			_once = true
		elif s == "--insecure":
			_insecure = true
		elif s == "--no-aggro":
			_aggro = false
		elif s == "--no-cache-plan":
			_no_cache = true
		elif s == "--cache-plan":
			_no_cache = false       # 切回"一回合只搜一次、后面照计划执行"的旧口径（默认已是每手重搜）
		elif s.begins_with("--beam="):
			_beam = int(s.substr(7))            # 搜索宽度覆盖（不动权重文件）
		elif s.begins_with("--min-think="):
			_min_think = maxi(int(s.substr(12)), 0)   # 每手最少思考毫秒（0 = 关掉"垫时间"）
		elif s == "--no-watch":
			_watch_on = false
		elif s.begins_with("--watch-port="):
			_watch_port = int(s.substr(13))
		elif s == "--quiet":
			_quiet = true
	_base = _base.rstrip("/")


func _env_or(key: String, dflt: String) -> String:
	var v := OS.get_environment(key)
	return v if v != "" else dflt


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)


func _log_verbose(msg: String) -> void:
	if not _quiet:
		print(LOG_PREFIX + msg)


# ============================================================ HTTP ============================================================

## 一次 HTTP 调用。返回：
##   {"ok": true,  "status": 2xx, "json": Variant}          —— 成功（204 时 json = null）
##   {"ok": false, "status": <http码或0>, "error_code": "...", "error_msg": "...", "net": <ERR_*>}
## 网络层失败与 5xx/429 由调用方决定重试；4xx 一般按错误码分支处理（见协议 §9）。
func _req(method: int, path: String, body: Variant = null, timeout_s: float = CMD_HTTP_TIMEOUT_S) -> Dictionary:
	var r := HTTPRequest.new()
	r.timeout = timeout_s
	if _insecure:
		r.set_tls_options(TLSOptions.client_unsafe())
	add_child(r)
	var headers := PackedStringArray(["Authorization: Bearer " + _token, "Accept: application/json"])
	var payload := ""
	if body != null:
		headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	var err := r.request(_base + path, headers, method, payload)
	if err != OK:
		r.queue_free()
		return {"ok": false, "status": 0, "net": err, "error_code": "REQUEST_FAILED",
			"error_msg": "HTTPRequest.request 直接失败 err=%d" % err}
	var res: Array = await r.request_completed
	r.queue_free()
	var result_code: int = int(res[0])
	var http_code: int = int(res[1])
	var raw: PackedByteArray = res[3]
	var text := raw.get_string_from_utf8()
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "net": result_code,
			"error_code": "NETWORK", "error_msg": _result_name(result_code)}
	var json: Variant = null
	if text.strip_edges() != "":
		json = JSON.parse_string(text)
		if json == null:
			return {"ok": false, "status": http_code, "error_code": "BAD_JSON",
				"error_msg": "响应不是 JSON：%s" % text.substr(0, 200)}
	if http_code >= 200 and http_code < 300:
		return {"ok": true, "status": http_code, "json": json}
	var ec := ""
	var em := ""
	if json is Dictionary and json.has("error") and json["error"] is Dictionary:
		ec = String(json["error"].get("code", ""))
		em = String(json["error"].get("message", ""))
	return {"ok": false, "status": http_code, "error_code": ec, "error_msg": em,
		"body": text.substr(0, 300)}


func _result_name(code: int) -> String:
	match code:
		HTTPRequest.RESULT_CANT_CONNECT: return "连不上（地址/端口/网络）"
		HTTPRequest.RESULT_CANT_RESOLVE: return "域名解析不了"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "连接中断"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "TLS 握手失败（证书不受信？试 --insecure）"
		HTTPRequest.RESULT_TIMEOUT: return "请求超时"
		_: return "HTTPRequest 结果码 %d" % code


## 退避等待（网络错误 / 5xx / 429）。attempt 从 0 开始。
func _backoff(attempt: int) -> void:
	var base: float = BACKOFF_S[min(attempt, BACKOFF_S.size() - 1)]
	var wait := base + randf() * 0.3
	await get_tree().create_timer(wait).timeout


func _is_retryable(res: Dictionary) -> bool:
	if not res["ok"]:
		if int(res.get("net", 0)) != 0:
			return true
		var st := int(res["status"])
		# 409 POLL_IN_PROGRESS = "这台引擎已经有一个领取循环了"：多半是上一个实例还没退干净
		# （重启时的重叠窗口）⇒ 退避重试，别直接自杀。
		if st == 409 and String(res.get("error_code", "")) == "POLL_IN_PROGRESS":
			return true
		return st == 429 or st >= 500
	return false


# ============================================================ 主循环 ============================================================

func _main() -> void:
	# 1) 验令牌
	var me = await _retry_forever(func(): return await _req(HTTPClient.METHOD_GET, "/engines/me"), "GET /engines/me")
	if me == null:
		return
	_engine = me
	_log("引擎：%s（%s）状态=%s 规则=%s" % [
		String(_engine.get("name", "?")), String(_engine.get("version", "?")),
		String(_engine.get("status", "?")), str(_engine.get("supportedRulesVersions", []))])
	# 2) 拉当前规则包
	await _load_rules()
	# 2b) 兼容性自检：登记的规则版本列表里**没有**当前规则包 ⇒ 网页那边根本选不了我们开赛
	#     （协议 §7：不兼容开赛直接 422 RULES_MISMATCH）。2026-10-01 服务器换版实测：
	#     当前版本换成 tb-b280…，而条目仍写着 tb-61ae…，`/rules` 的 availableRulesVersions 只剩新版
	#     ⇒ 条目等于废了，必须到网页「接入引擎」按当前规则版本**重新登记一个条目**（旧条目改不了
	#     支持列表，管理接口只有建/轮换令牌/停用/授权）。
	var supported: Array = _engine.get("supportedRulesVersions", [])
	if _rules_version != "" and not supported.has(_rules_version):
		_warn_compat(supported)

	# 3) 建 AI 桥
	_bridge = load("res://arena/ArenaBridge.gd").new()
	_bridge.setup(self, _rules, _tier, _think_ms, _policy, not _no_cache, _aggro, _beam, _min_think)
	_log("AI 桥就绪：tier=%d；合法动作 %s；%s" % [
		_tier, "随机" if _policy == "random" else "走项目 AI",
		("每一手都重搜（默认；--cache-plan 可切回'一回合只搜一次'）" if _no_cache else "一回合只搜一次 + 计划缓存")])
	# 3b) 本地思考面板（浏览器看 AI 每一手在想什么）
	if _watch_on:
		_watch = load("res://arena/ArenaWatch.gd").new()
		_watch.name = "ArenaWatch"
		add_child(_watch)
		_watch.start(_watch_port, func(m: String) -> void: _log(m))
		_bridge.set_watch(_watch)
	_log("待命，开始长轮询…")
	# 4) 领取循环
	await _loop()


## 反复重试直到成功；遇到不可恢复的鉴权/配置错误返回 null（并停进程）。
func _retry_forever(call: Callable, what: String) -> Variant:
	var attempt := 0
	while not _stop:
		var res: Dictionary = await call.call()
		if res["ok"]:
			return res["json"]
		if int(res["status"]) == 401 or int(res["status"]) == 403:
			_log("!! %s 被拒：%s %s（令牌失效/无权限，停止）" % [what, res["error_code"], res["error_msg"]])
			get_tree().quit(3)
			return null
		if not _is_retryable(res):
			_log("!! %s 失败：HTTP %d %s %s（不重试）" % [what, int(res["status"]), res["error_code"], res["error_msg"]])
			get_tree().quit(4)
			return null
		_log_verbose("%s 临时失败（%s/%s），%.1fs 后重试" % [what, res["error_code"], res["error_msg"], BACKOFF_S[min(attempt, BACKOFF_S.size() - 1)]])
		await _backoff(attempt)
		attempt += 1
	return null


## 【兼容性自检】当前规则包不在登记的支持列表里 ⇒ 网页选不了我们开赛（协议 §7 会 422 RULES_MISMATCH）。
## 这不是"能不能打赢"的问题，是**根本开不了局**，必须让用户去网页按当前规则版本重新登记条目。
func _warn_compat(supported: Array) -> void:
	_log("!! 规则版本不兼容：当前规则包=%s，本条引擎登记的支持列表=%s（服务器可开赛版本=%s）" % [
		_rules_version, str(supported), str(_rules_available)])
	_log("!! ⇒ 网页「接入引擎」里按当前规则版本**重新登记一个条目**，把新令牌给引擎（旧条目改不了支持列表）。")


func _load_rules() -> void:
	var list = await _retry_forever(func(): return await _req(HTTPClient.METHOD_GET, "/rules"), "GET /rules")
	if list == null:
		return
	var ver := ""
	if list is Dictionary:
		ver = String(list.get("currentRulesVersion", ""))
		_rules_available = list.get("availableRulesVersions", [])
	if ver == "":
		_log("!! /rules 没给 currentRulesVersion：%s" % str(list))
		return
	var bundle = await _retry_forever(func(): return await _req(HTTPClient.METHOD_GET, "/rules/" + ver), "GET /rules/" + ver)
	if bundle == null:
		return
	_rules = bundle
	_rules_version = ver
	# 规则包存一份到本地：离线对账器（arena/对账复盘.tscn）要拿它做 kind→hero 映射，免得再联网
	var dir := ProjectSettings.globalize_path("res://arena/记录")
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open("%s/规则包.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(bundle))
		f.close()
	var heroes: Array = _rules.get("heroes", [])
	_log("规则包 %s：英雄 %d 项、棋盘 %d 格" % [ver, heroes.size(), int((_rules.get("board", {}) as Dictionary).get("cells", []).size())])


func _loop() -> void:
	var attempt := 0
	while not _stop:
		var res: Dictionary = await _req(HTTPClient.METHOD_POST, "/tasks/next", {"waitMs": POLL_WAIT_MS}, POLL_HTTP_TIMEOUT_S)
		if _stop:
			break
		if res["ok"]:
			attempt = 0
			var task: Variant = res["json"]
			if task == null:
				continue   # 204：没任务，继续领
			if task is Dictionary:
				await _handle_task(task)
			continue
		# 409 POLL_IN_PROGRESS：本进程只该有一个轮询循环，出现说明上一轮没结束 —— 退避后重来
		if int(res["status"]) == 401 or int(res["status"]) == 403:
			_log("!! 领取任务被拒：%s %s（停止）" % [res["error_code"], res["error_msg"]])
			get_tree().quit(3)
			return
		if _is_retryable(res):
			_log_verbose("领取任务临时失败（%s/%s），退避重试" % [res["error_code"], res["error_msg"]])
			await _backoff(attempt)
			attempt += 1
			continue
		_log("!! 领取任务失败：HTTP %d %s %s" % [int(res["status"]), res["error_code"], res["error_msg"]])
		get_tree().quit(4)
		return
	if not _stop:
		_log("循环结束")


func _handle_task(task: Dictionary) -> void:
	var t := String(task.get("type", ""))
	if t == "decision":
		await _handle_decision(task)
	elif t == "match_end":
		await _handle_match_end(task)
	else:
		_log("!! 不认识的任务类型 %s：%s" % [t, str(task).substr(0, 200)])


# ------------------------------------------------------------ 取证落盘 ------------------------------------------------------------
# 为什么落盘：协议不给"裁判内部怎么算的"，能拿到的只有①每一手的**真观察** ②终局后公开的**回放事件流**。
# 两样都存下来，才能事后把"我们的规则 vs 裁判的规则"逐条对出来（已有的差异登记在 `arena/规则差异台账.md`）。
# 文件：arena/记录/<matchId>.jsonl（每行一个 JSON：本手任务原文 + 我们选的动作）
#       arena/记录/<matchId>.回放.json（终局后自动拉一次公开回放）

var _rec_f: FileAccess = null
var _rec_match := ""


func _record(payload: Dictionary, tag: String) -> void:
	var mid := String(payload.get("matchId", "?"))
	if _rec_f == null or _rec_match != mid:
		_close_record()
		var dir := ProjectSettings.globalize_path("res://arena/记录")
		DirAccess.make_dir_recursive_absolute(dir)
		var path := "%s/%s.jsonl" % [dir, mid]
		# ⚠️ 第一版这里一律用 READ_WRITE —— 那个模式**要求文件已存在**，于是第一局的 jsonl 根本没落盘
		#    （回放照样下来了，因为回放走的是 WRITE）。改成：不存在就 WRITE 建、存在就 READ_WRITE + 追尾。
		if FileAccess.file_exists(path):
			_rec_f = FileAccess.open(path, FileAccess.READ_WRITE)
			if _rec_f != null:
				_rec_f.seek_end()
		else:
			_rec_f = FileAccess.open(path, FileAccess.WRITE)
		_rec_match = mid
		if _rec_f == null:
			_log("!! 记录打不开（%s）：本次不落盘" % path)
			return
	_log_record({"at": Time.get_time_string_from_system(), "tag": tag, "data": payload})


func _log_record(line: Dictionary) -> void:
	if _rec_f == null:
		return
	_rec_f.store_line(JSON.stringify(line))
	_rec_f.flush()


func _close_record() -> void:
	if _rec_f != null:
		_rec_f.close()
		_rec_f = null
	_rec_match = ""


## 终局后把公开回放也拉下来（协议：终局比赛的回放是公开的）
func _fetch_replay(match_id: String) -> void:
	var res: Dictionary = await _req(HTTPClient.METHOD_GET, "/matches/%s/replay" % match_id)
	if not res["ok"]:
		_log_verbose("回放没拉到（%s %s）" % [res["error_code"], res["error_msg"]])
		return
	var dir := ProjectSettings.globalize_path("res://arena/记录")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/%s.回放.json" % [dir, match_id]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(res["json"]))
	f.close()
	_log("回放已存：%s" % path)


# ------------------------------------------------------------ 决策任务 ------------------------------------------------------------

func _handle_decision(task: Dictionary) -> void:
	var task_id := String(task.get("taskId", ""))
	var legal: Array = task.get("legalActions", [])
	var obs: Dictionary = task.get("observation", {})
	if legal.is_empty():
		# 协议保证非终局任务 legalActions 非空；真空了就是裁判侧异常，照实报出来
		_log("!! 任务 %s 没有任何合法动作（phase=%s turn=%s），跳过" % [task_id, obs.get("phase", "?"), obs.get("turnCount", "?")])
		return
	_record(task, "task")
	var remain := int(task.get("remainingMs", 0))
	var t0 := Time.get_ticks_msec()
	var pick = _bridge.choose(task)
	var think := Time.get_ticks_msec() - t0
	if pick.is_empty() or not pick.has("actionId"):
		_log("!! 桥没给出动作，退化成任取一个合法动作")
		pick = {"actionId": String(legal[0].get("actionId", "")), "note": "fallback-first-legal"}
	var detail := _describe(obs, pick, legal)
	_log_verbose("决策 %s｜局 %s｜phase=%s turn=%d%s｜剩余%dms 想了%dms｜选 %s" % [
		task_id, String(task.get("matchId", "?")), String(obs.get("phase", "?")), int(obs.get("turnCount", 0)),
		"" if remain <= 0 else "（本阶段预算）", remain, think, detail])
	var receipt = await _submit(task_id, int(task.get("stateSeq", 0)), String(pick["actionId"]))
	if receipt == null:
		return
	_record({"matchId": String(task.get("matchId", "?")), "chosen": pick, "intent": _find_intent(legal, String(pick["actionId"])),
		"stateSeq": int(task.get("stateSeq", 0))}, "chosen")
	_task_count += 1
	if _max_tasks > 0 and _task_count >= _max_tasks:
		_log("已处理 %d 个决策任务（--max-tasks），退出" % _task_count)
		_stop = true
		get_tree().quit(0)


## 提交动作。相同 taskId+stateSeq+actionId 可安全重试（协议 §3.4）。
## 返回 null = 该任务已作废/被别人解决 → 回领取循环。
func _submit(task_id: String, state_seq: int, action_id: String) -> Variant:
	var body := {"stateSeq": state_seq, "actionId": action_id}
	var attempt := 0
	while not _stop:
		var res: Dictionary = await _req(HTTPClient.METHOD_POST, "/tasks/%s/action" % task_id, body)
		if res["ok"]:
			var j: Dictionary = res["json"] if res["json"] is Dictionary else {}
			_log_verbose("提交成功 appliedStateSeq=%s matchStatus=%s" % [str(j.get("appliedStateSeq", "?")), str(j.get("matchStatus", "?"))])
			return j
		var st := int(res["status"])
		var ec := String(res["error_code"])
		if st == 401 or st == 403:
			_log("!! 提交被拒：%s（停止）" % ec)
			_stop = true
			get_tree().quit(3)
			return null
		if ec == "STALE_TASK" or ec == "STATE_MISMATCH" or ec == "ALREADY_RESOLVED":
			_log_verbose("任务已失效（%s），回领取循环" % ec)
			return null
		if ec == "INVALID_ACTION":
			_log("!! 裁判说动作非法（INVALID_ACTION）——映射有问题，回领取循环重算")
			return null
		if _is_retryable(res):
			_log_verbose("提交临时失败（%s/%s），原样重试" % [ec, res["error_msg"]])
			await _backoff(attempt)
			attempt += 1
			continue
		_log("!! 提交失败：HTTP %d %s %s（不重试）" % [st, ec, res["error_msg"]])
		return null
	return null


func _describe(obs: Dictionary, pick: Dictionary, legal: Array) -> String:
	var intent := _find_intent(legal, String(pick.get("actionId", "")))
	return "%s ← %s（合法 %d 个）%s" % [
		String(pick.get("note", "")), intent, legal.size(),
		("" if _rules_version == "" else "")]


func _find_intent(legal: Array, action_id: String) -> String:
	for a in legal:
		if a is Dictionary and String(a.get("actionId", "")) == action_id:
			return _intent_text(a.get("intent", {}))
	return "?"


func _intent_text(it: Variant) -> String:
	if not (it is Dictionary):
		return "?"
	var d: Dictionary = it
	var k := String(d.get("kind", "?"))
	match k:
		"DEPLOY":
			return "DEPLOY slot%d→%s" % [int(d.get("slot", -1)), _cell_text(d.get("to", null))]
		"MOVE":
			return "MOVE %s→%s" % [String(d.get("heroId", "?")), _cell_text(d.get("to", null))]
		"ATTACK":
			return "ATTACK %s→%s" % [String(d.get("heroId", "?")), _cell_text(d.get("target", null))]
		"WITHDRAW":
			return "WITHDRAW %s" % String(d.get("heroId", "?"))
		_:
			return k


func _cell_text(c: Variant) -> String:
	if c is Dictionary:
		return "(%s,%s)" % [str(c.get("x", "?")), str(c.get("y", "?"))]
	return "?"


# ------------------------------------------------------------ 结束通知 ------------------------------------------------------------

func _handle_match_end(task: Dictionary) -> void:
	var task_id := String(task.get("taskId", ""))
	var match_id := String(task.get("matchId", ""))
	if not _ack_pending.has(match_id):
		_ack_pending[match_id] = true
		var r: Dictionary = task.get("result", {})
		_log("比赛结束 %s｜我方=%s｜status=%s winner=%s reason=%s turns=%s 回放=%s" % [
			match_id, String(task.get("side", "?")), String(r.get("status", "?")),
			# ⚠️ 这里必须用 `str()`：平局/未完时 `winner` 是 JSON null ⇒ `String(null)` 会抛
			#   "Nonexistent 'String' constructor"，把整段结束处理（含自动取证回放）一起打断
			#   （2026-10-01 实测 arena_ba8d6597 就是这么丢掉回放的）。
			str(r.get("winner", "null")), str(r.get("reason", "")),
			str(r.get("turnCount", "?")), str(r.get("replayUrl", ""))])
		if _bridge != null:
			_bridge.on_match_end(match_id)
		await _fetch_replay(match_id)
		_log("本局取证：arena/记录/%s.jsonl（每手真观察）+ %s.回放.json（裁判事件流）" % [match_id, match_id])
		_close_record()
	# ACK（可重复；404 = 通知过期，放弃）
	var attempt := 0
	while not _stop:
		var res: Dictionary = await _req(HTTPClient.METHOD_POST, "/tasks/%s/ack" % task_id, {})
		if res["ok"]:
			_log_verbose("结束通知已确认 %s" % task_id)
			break
		if int(res["status"]) == 404:
			_log_verbose("结束通知已过期（404），放弃确认")
			break
		if int(res["status"]) == 401 or int(res["status"]) == 403:
			_log("!! ACK 被拒（停止）")
			_stop = true
			get_tree().quit(3)
			return
		if _is_retryable(res):
			await _backoff(attempt)
			attempt += 1
			continue
		_log("!! ACK 失败：HTTP %d %s %s" % [int(res["status"]), res["error_code"], res["error_msg"]])
		break
	if _once:
		_log("收到一场结束通知（--once），退出")
		_stop = true
		get_tree().quit(0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_stop = true
