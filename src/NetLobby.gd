extends Control
## 联机大厅：开房（主机）/ 加入（客户端），支持 普通模式（双方各选缓存卡组槽）/ 竞技场模式。
## 双方都选好卡组后，主机广播 start，双端进入 Main 开一场联机对局（Battle 接指令层）。

const PORT := 18861
const NET_VERSION := 2   # 联机协议版本：凡协议不兼容的改动（如卡组上传）都 +1；双方必须一致才能开战
const SLOTS := [1, 2, 3]
const MIN_PICK := 5   # 与选人界面一致：普通模式卡组最少人数（不足 5 人也保存，开战时拦下提示）
const PICK_COUNT := 8   # 与选人界面一致：整队人数上限

var _status: Label
var _ip: LineEdit
var _btn_start: Button
var _btn_confirm: Button   # 确认卡组后才把选择发给对方
var _btn_ready: Button = null   # 竞技场：加入方"准备完毕"
var _my_ready := false     # 竞技场：本端是否已准备（加入方）
var _peer_ready := false   # 竞技场：对端是否已准备（主机判断能否开始）
var _deck_info: Label = null   # 所选卡组状态展示行
var _slot_head: HBoxContainer = null   # "选择你的卡组槽"标题行（含右侧"编辑卡组"按钮；竞技场整行隐藏）
var _preview_host: Control = null      # 所选卡组队伍小卡预览（与普通模式同款）
var _hover_tooltip: PanelContainer = null   # 悬停英雄属性浮层
var _hover_box: VBoxContainer = null        # 浮层内容
var _btn_edit: Button = null           # "编辑卡组"按钮（跳普通模式选人页编辑）
var _slot_label: Label = null  # 卡组槽区域标题（竞技场模式整体隐藏）
var _btn_host: Button
var _btn_join: Button
var _slot_btn: Array = []
var _mode_label: Label
var _mode_btn: Array = []   # [普通按钮, 竞技场按钮]：客户端跟随主机时禁用

var _mode := "normal"    # "normal" / "arena"
var _my_slot := 1        # 本端查看/选用的卡组槽（默认槽1；0=未选）
var _my_confirmed := false   # 本端是否已点"确认卡组"（确认后才把选择发给对方）
var _peer_slot := 0      # 对端选的卡组槽（收到对端"确认"消息后才有值）
var _peer_deck: Array = []   # 对端槽位对应的卡组内容（客户端选槽时把自己本机的卡组发过来）
var _peer_online := false   # 对端是否已连上（收到 hello/选槽消息即置 true）
var _ver_mismatch := false   # 双方版本不一致（禁止开始对局）
var _connecting_sec := 0.0   # 客户端尝试连接已耗时（超时自动取消）
var _connected_ok := false   # 是否已真正建立连接（连接成功后不再触发"连接超时"）
var _last_join_addr := ""    # 最近一次以客户端身份加入的主机地址（断线自动重连用）
var _last_join_port := NetBus.DEFAULT_PORT
var _am_host := false        # 本次会话是否为开房主机
var _auto_retry_done := false   # 本次会话是否已自动重连过一次（只试一次）
var _session_started := false    # 本次会话是否已成功开房或连上（用于点亮"重新连接"）
var _btn_reconnect: Button = null   # 手动重新连接按钮
var _addr_history: OptionButton = null   # 历史主机地址下拉框（连成功过的地址）
var _addrs: Array = []              # 历史主机地址（最近成功连接的排最前）

const ADDR_SAVE_PATH := "user://net_addrs.cfg"   # 历史地址持久化（关游戏不丢）
const ADDR_HISTORY_MAX := 8

func _ready() -> void:
	_load_addrs()
	_build()
	NetBus.packet_received.connect(_on_packet)
	NetBus.connected.connect(_on_connected)
	# 用对象方法连接 autoload 信号：大厅释放时自动断开，避免 Lambda capture freed
	NetBus.disconnected.connect(_on_net_disconnected)
	# 恢复"上次会话"（对局退回大厅后场景重建，靠 GameState 记录让「重新连接」仍可用）
	_last_join_addr = GameState.net_last_addr
	_last_join_port = GameState.net_last_port
	_am_host = GameState.net_last_was_host
	_session_started = GameState.net_last_joined
	_refresh_ui()

func _on_net_disconnected() -> void:
	if not is_instance_valid(_status):
		return
	NetBus.stop()   # 断开即彻底停止连接，让"加入/开房"立刻可再次点击
	if _ver_mismatch:
		# 版本不符导致的断开：保留原因提示（普通断线消息会盖掉原因）
		_ver_mismatch = false
		_status.text = "因版本不一致已断开。请双方使用同一版本的游戏（本机 v%d）。" % NET_VERSION
		_connected_ok = false
		_peer_online = false
		_peer_ready = false
		_peer_slot = 0
		_peer_deck = []
		_refresh_ui()
		return
	_status.text = "连接已断开"
	_connected_ok = false
	_peer_online = false
	_peer_ready = false
	_my_ready = false
	_peer_slot = 0
	_peer_deck = []
	_refresh_ui()
	# 容错：此前以客户端身份连上后意外断开 -> 自动重连一次（安卓退后台回来网络被系统重置的典型场景）
	if not _am_host and _last_join_addr != "" and not _auto_retry_done:
		_auto_retry_done = true
		_status.text = "连接断开，正在自动重连 %s:%d…" % [_last_join_addr, _last_join_port]
		NetBus.join_match(_last_join_addr, _last_join_port)
		if NetBus.is_online and not NetBus.is_host:
			_connecting_sec = 0.0
			_connected_ok = false   # 等 _on_connected 后置 true
			_status.text = "正在自动重连 %s:%d…" % [_last_join_addr, _last_join_port]
		else:
			_status.text = "自动重连失败：%s。请点击「加入」手动重试。" % NetBus.last_tick_error

# 版本不匹配处理（主机在收到 hello 时调用；pv=对端版本，老版本客户端没有版本号按 0）
func _reject_version(pv: int) -> void:
	_ver_mismatch = true
	if NetBus.is_host:
		NetBus.send_all(JSON.stringify({ "type": "ver_err", "mine": NET_VERSION, "theirs": pv }))
	_status.text = "版本不一致：本机 v%d、对方 v%d。请双方使用同一个版本的游戏再联机。" % [NET_VERSION, pv]
	_refresh_ui()

func _process(dt: float) -> void:
	if NetBus._peer != null and NetBus.last_tick_error != "":
		_status.text = "错误: %s" % NetBus.last_tick_error
	# 客户端"正在建立连接"超时：8 秒仍未连上则取消并提示。
	# 一旦真正连上（_connected_ok），不再倒计时——避免已连接等待开始/对局中被误断。
	if NetBus.is_online and not NetBus.is_host and not _connected_ok:
		_connecting_sec += dt
		if _connecting_sec > 8.0:
			_status.text = "连接超时，请确认对方已开房且地址/端口正确。已停止连接。"
			NetBus.stop()
			_refresh_ui()
	elif NetBus.is_online and NetBus.is_host and not _connected_ok:
		# 主机开房即视为已就绪（等待对方加入），不计连接超时
		_connecting_sec = 0.0
	elif not NetBus.is_online:
		_connecting_sec = 0.0
	# 悬停属性浮层跟随鼠标（有内容时）
	if _hover_tooltip != null and _hover_tooltip.visible:
		var vsize := get_viewport().get_visible_rect().size
		var pos := get_viewport().get_mouse_position() + Vector2(16, 16)
		pos.x = minf(pos.x, vsize.x - _hover_tooltip.size.x - 6.0)
		pos.y = minf(pos.y, vsize.y - _hover_tooltip.size.y - 6.0)
		_hover_tooltip.position = pos

# ---- 网络回调 ----
func _on_connected() -> void:
	_status.text = "✅ 已连接（%s）" % ("主机" if NetBus.is_host else "客户端")
	_connected_ok = true
	_session_started = true
	_connecting_sec = 0.0
	GameState.note_net_room(true, _last_join_addr, _last_join_port, NetBus.is_host)
	if not NetBus.is_host and _last_join_addr != "":
		# 以客户端身份**真的连上**了：把这个主机地址记进历史下拉框
		# （端口是默认值时只记 IP，非默认才带 ":端口"，与手填格式一致）
		var disp := _last_join_addr
		if _last_join_port != NetBus.DEFAULT_PORT:
			disp = "%s:%d" % [_last_join_addr, _last_join_port]
		_remember_addr(disp)
	if not NetBus.is_host:
		NetBus.send_to(1, JSON.stringify({ "type": "hello", "ver": NET_VERSION }))
	_refresh_ui()

func _on_packet(_from: int, text: String) -> void:
	var cmd: Variant = JSON.parse_string(text)
	if not (cmd is Dictionary):
		if text == "hello" and NetBus.is_host:
			# 老版本客户端没有版本号：视为不兼容（v0），拒绝组队
			_reject_version(0)
		else:
			_status.text = "收到: %s" % text
		return
	var t := String(cmd.get("type", ""))
	match t:
		"hello":
			if NetBus.is_host:
				var pv := int(cmd.get("ver", 0))
				if pv != NET_VERSION:
					_reject_version(pv)   # 版本不符：提示并阻止开战
					return
				_peer_online = true
				_peer_ready = false   # 新加入方需重新点"准备完毕"
				# 把当前模式补发给刚加入的客户端（若主机在客户端加入前已选模式，对方收不到历史广播）。
				# 注：必须用广播 send_all —— ENet 客户端 uid 是随机分配的，主机定向 send_to(固定id) 到不了对端；
				# 全项目主机->客户端（对局指令同步等）均用 send_all，双端场景下广播=发给唯一对端。
				NetBus.send_all(JSON.stringify({ "type": "mode", "mode": _mode }))
				if _my_confirmed and _my_slot > 0:
					# 主机在客人加入前就已确认卡组：补发一次，否则客人永远看不到主机已确认
					_send_my_confirmation()
					_status.text = "我方卡组已确认，等待对方确认…"
				else:
					_status.text = "✅ 对端已加入，%s" % ("等待对方点击「准备完毕」…" if _mode == "arena" else "请双方选择卡组")
				_refresh_ui()
		"choseslot":  # 对端选了卡组槽（带自己本机的卡组内容；仅普通模式有意义）
			if _mode == "normal":
				_peer_slot = int(cmd.get("slot", 0))
				var d: Array = cmd.get("deck", [])
				if d.size() > 0:
					_peer_deck = d
				_peer_online = true
				# 不暴露对方卡组信息（数量/名单都不显示），只提示已确认状态。
				if d.size() == 0:
					_status.text = "对方已确认卡组（其卡组为空，无法开始对局）"
				elif d.size() < MIN_PICK:
					_status.text = "对方已确认卡组（其卡组不足 %d 人，无法开始对局）" % MIN_PICK
				else:
					_status.text = "对方已确认卡组"
				_refresh_ui()
				_maybe_start()
		"choseslot_cancel":  # 对端取消了卡组确认（可重新选择；仅普通模式有意义）
			if _mode == "normal":
				_peer_slot = 0
				_peer_deck = []
				_status.text = "对方取消了卡组确认，等待重新确认…"
				_refresh_ui()
				if NetBus.is_host:
					_maybe_start()
		"arena_ready":  # 加入方已点"准备"（仅主机处理；普通模式与竞技场通用）
			if NetBus.is_host:
				_peer_ready = true
				_status.text = "对方已准备完毕，可以开始"
				_refresh_ui()
				_maybe_start()
		"arena_unready":  # 加入方取消准备
			if NetBus.is_host:
				_peer_ready = false
				_status.text = "对方取消了准备"
				_refresh_ui()
		"start":
			_last_start = cmd
			_peer_mode = String(cmd.get("mode", "normal"))   # 以 start 消息里的模式为准
			_go_to_match_online()
		"mode":
			_peer_mode = String(cmd.get("mode", "normal"))
			# 客户端跟随主机选择的模式
			if not NetBus.is_host:
				_mode = _peer_mode
				if _mode == "arena":
					_enter_arena_mode()   # 清掉普通模式卡组确认类提醒（含"对方取消了卡组确认"等）
				else:
					_enter_normal_mode()
		"ver_err":  # 主机通知版本不符
			if not NetBus.is_host:
				var minev := int(cmd.get("mine", 0))
				var theirs := int(cmd.get("theirs", 0))
				_status.text = "版本不一致：主机 v%d、本机 v%d。请双方使用同一版本的游戏。" % [minev, theirs]
				_ver_mismatch = true
				NetBus.stop()   # 版本不符：断开，换用同一版本后再加入
				_refresh_ui()

var _peer_mode := "normal"
var _last_start: Dictionary = {}

# ---- UI ----
# 界面背景贴图（与主菜单同一张）：按顺序取【第一个能加载的】；全缺图 ⇒ 返回 null ⇒ 只剩纯色底。
# 换图只需把想用的那张挪到最前（或直接替换文件内容）。
const COVER_BG_CANDIDATES := [
	"res://assets/美术资源/背景/界面背景_六角地砖.jpg",
]

func _make_cover_bg() -> TextureRect:
	for path in COVER_BG_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var tex := load(path) as Texture2D
		if tex == null:
			continue
		var r := TextureRect.new()
		r.texture = tex
		r.set_anchors_preset(Control.PRESET_FULL_RECT)
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED   # 等比裁切铺满，不变形
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE               # 不能吃掉按钮点击
		return r
	return null

func _build() -> void:
	# 背景：纯色底 → 界面背景贴图（等比裁切铺满）→ 轻微压暗（三层都不接收鼠标）
	var bg := WoodFloor.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var cover := _make_cover_bg()
	if cover != null:
		add_child(cover)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.12)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var vbox := VBoxContainer.new()
	vbox.position = Vector2(28, 44)
	vbox.size = Vector2(get_viewport().get_visible_rect().size.x - 56, get_viewport().get_visible_rect().size.y - 96)
	vbox.add_theme_constant_override("separation", 18)
	add_child(vbox)

	var title := Label.new()
	title.text = "联机对战"
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_status = Label.new()
	_status.text = "未连接"
	_status.add_theme_font_size_override("font_size", 20)
	_status.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status)

	# 模式选择（仅主机可选；客户端跟随主机）
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 14)
	vbox.add_child(mode_row)
	var btn_normal := Button.new()
	btn_normal.text = "普通模式"
	btn_normal.custom_minimum_size = Vector2(0, 58)
	btn_normal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_normal.add_theme_font_size_override("font_size", 24)
	btn_normal.pressed.connect(func(): _pick_mode("normal"))
	mode_row.add_child(btn_normal)
	var btn_arena := Button.new()
	btn_arena.text = "竞技场模式"
	btn_arena.custom_minimum_size = Vector2(0, 58)
	btn_arena.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_arena.add_theme_font_size_override("font_size", 24)
	btn_arena.pressed.connect(func(): _pick_mode("arena"))
	mode_row.add_child(btn_arena)
	_mode_btn = [btn_normal, btn_arena]
	_mode_label = Label.new()
	_mode_label.add_theme_font_size_override("font_size", 20)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_mode_label)

	_btn_host = Button.new()
	_btn_host.text = "开房（作为主机）"
	_btn_host.custom_minimum_size = Vector2(0, 62)
	_btn_host.add_theme_font_size_override("font_size", 24)
	_btn_host.pressed.connect(_on_host)
	vbox.add_child(_btn_host)

	var ip_label := Label.new()
	ip_label.text = "主机地址（客户端填写）:"
	ip_label.add_theme_font_size_override("font_size", 18)
	ip_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	vbox.add_child(ip_label)

	# 历史地址下拉框：连成功过的主机地址存在这里，选一条即填进下面的输入框
	# （填完仍可直接改端口再点「加入」；不选就照旧手填）
	_addr_history = OptionButton.new()
	_addr_history.custom_minimum_size = Vector2(0, 46)
	_addr_history.add_theme_font_size_override("font_size", 18)
	_addr_history.item_selected.connect(_on_history_picked)
	vbox.add_child(_addr_history)
	_refresh_addr_history()

	_ip = LineEdit.new()
	_ip.text = "127.0.0.1"
	_ip.custom_minimum_size = Vector2(0, 54)
	_ip.add_theme_font_size_override("font_size", 22)
	vbox.add_child(_ip)

	_btn_join = Button.new()
	_btn_join.text = "加入（作为客户端）"
	_btn_join.custom_minimum_size = Vector2(0, 62)
	_btn_join.add_theme_font_size_override("font_size", 24)
	_btn_join.pressed.connect(_on_join)
	vbox.add_child(_btn_join)

	# 重新连接：有本次会话记录后可点（客户端重连上次主机地址；主机重新开房）
	_btn_reconnect = Button.new()
	_btn_reconnect.text = "重新连接"
	_btn_reconnect.custom_minimum_size = Vector2(0, 50)
	_btn_reconnect.add_theme_font_size_override("font_size", 20)
	_btn_reconnect.disabled = true
	_btn_reconnect.pressed.connect(_on_reconnect)
	vbox.add_child(_btn_reconnect)

	# 卡组槽选择（普通模式；竞技场模式整块隐藏）
	var slot_head := HBoxContainer.new()
	slot_head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(slot_head)
	_slot_head = slot_head
	var slot_label := Label.new()
	slot_label.text = "选择你的卡组槽（普通模式）："
	slot_label.add_theme_font_size_override("font_size", 20)
	slot_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot_head.add_child(slot_label)
	_slot_label = slot_label
	var head_space := Control.new()
	head_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot_head.add_child(head_space)
	var edit_btn := Button.new()
	edit_btn.text = "编辑卡组"
	edit_btn.custom_minimum_size = Vector2(0, 48)
	edit_btn.add_theme_font_size_override("font_size", 20)
	edit_btn.pressed.connect(_open_deck_editor)
	slot_head.add_child(edit_btn)
	_btn_edit = edit_btn
	var slot_row := HBoxContainer.new()
	slot_row.add_theme_constant_override("separation", 10)
	vbox.add_child(slot_row)
	for s in SLOTS:
		var b := Button.new()
		b.text = "槽%d" % s
		b.custom_minimum_size = Vector2(0, 58)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 24)
		b.pressed.connect(_choose_slot.bind(s))
		_slot_btn.append(b)
		slot_row.add_child(b)
	# 所选卡组队伍预览：与普通模式卡组槽/替补队伍同款一行小卡（悬停无动作）
	_preview_host = Control.new()
	_preview_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_preview_host)
	# 卡组状态文案（阵容以卡面队列显示，这里只放状态）
	_deck_info = Label.new()
	_deck_info.text = "卡组：未选择"
	_deck_info.add_theme_font_size_override("font_size", 18)
	_deck_info.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	_deck_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_deck_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_deck_info)
	# 已去掉"确认卡组"按钮：普通模式与竞技场一致，由加入方点"准备"、主机开始对局
	# （队伍改为进入对战后选择，大厅只查看/编辑卡组）

	# 加入方点击"准备"后，主机才能开始对局（普通模式 / 竞技场通用）
	_btn_ready = Button.new()
	_btn_ready.text = "准备"
	_btn_ready.custom_minimum_size = Vector2(0, 60)
	_btn_ready.add_theme_font_size_override("font_size", 22)
	_btn_ready.disabled = true
	_btn_ready.pressed.connect(_on_ready_toggle)
	vbox.add_child(_btn_ready)

	_btn_start = Button.new()
	_btn_start.text = "开始对局"
	_btn_start.custom_minimum_size = Vector2(0, 62)
	_btn_start.add_theme_font_size_override("font_size", 24)
	_btn_start.disabled = true
	_btn_start.pressed.connect(_on_start)
	vbox.add_child(_btn_start)

	var btn_back := Button.new()
	btn_back.text = "返回"
	btn_back.custom_minimum_size = Vector2(0, 56)
	btn_back.add_theme_font_size_override("font_size", 22)
	btn_back.pressed.connect(_back_to_menu)
	vbox.add_child(btn_back)

	_build_hover_tooltip()
	_refresh_ui()

func _choose_slot(s: int) -> void:
	if not NetBus.is_online:
		return
	_my_slot = s
	_my_confirmed = false   # 换了槽位需重新确认
	var deck := DeckStore.load_deck(s)
	if deck.size() == 0:
		_status.text = "你选了槽 %d，但该槽未保存卡组（空槽无法开战：先点「编辑卡组」选够 %d 名）。" % [s, MIN_PICK]
	elif deck.size() < MIN_PICK:
		_status.text = "你选了槽 %d，但该卡组仅 %d 人（不足 %d）：请点「编辑卡组」补足后再确认。" % [s, deck.size(), MIN_PICK]
	# 有卡组时不再在顶部状态栏重复"你已选择…"（名单已显示在下方卡组展示里）
	_refresh_ui()

# 确认/取消确认卡组：确认后把选择发给对方；可取消以便重新选择槽位
func _on_confirm_slot() -> void:
	if not NetBus.is_online or _my_slot <= 0:
		return
	if _mode != "normal":
		return
	if _my_confirmed:
		# 取消确认：通知对方作废刚才的选择，本端可重新选槽
		_my_confirmed = false
		NetBus.send_all(JSON.stringify({ "type": "choseslot_cancel" }))
		_status.text = "已取消确认，可重新选择卡组"
		_refresh_ui()
		return
	# 确认前校验人数：少于 MIN_PICK 不发送（避免把不合法卡组发给对方）
	var my_deck := DeckStore.load_deck(_my_slot)
	if my_deck.size() < MIN_PICK:
		_status.text = "卡组（槽 %d）不足 %d 名英雄，无法确认：请点「编辑卡组」补足。" % [_my_slot, MIN_PICK]
		return
	_my_confirmed = true
	_send_my_confirmation()
	# 若对方早已确认，本端不再显示"等待对方确认"（否则后确认方会覆盖掉已完成状态）
	if _peer_slot > 0:
		_status.text = "双方已确认卡组，可以开始"
	else:
		_status.text = "我方卡组已确认，等待对方确认…"
	_refresh_ui()
	if NetBus.is_host:
		_maybe_start()   # 对方若已先确认：此处立即亮起「开始对局」

# 发送本端卡组确认（含卡组内容）。主机在客人加入后也会用它补发"历史确认"，
# 避免"主机先确认、客人后加入"时客人永远看不到主机已确认。
func _send_my_confirmation() -> void:
	if _my_slot <= 0:
		return
	var deck := DeckStore.load_deck(_my_slot)
	# 把本机该槽位的卡组内容一起发给主机：双方各自用自己的卡组，避免主机用自己机器上的卡顶替。
	NetBus.send_all(JSON.stringify({ "type": "choseslot", "slot": _my_slot, "deck": deck }))

# "准备/取消准备"（仅加入方；主机收到后才解锁「开始对局」）。普通模式与竞技场通用
func _on_ready_toggle() -> void:
	if not NetBus.is_online or NetBus.is_host:
		return
	# 还没和主机握手完成就点「准备」：这条消息发不出去（发出去也只是丢包 + ENet 报错），
	# 所以这里只提示、不改本地准备状态，避免"本地显示已准备、主机那边一直没收到"。
	if not NetBus.is_link_up():
		_status.text = "还没连上主机，请稍等一下再点「准备」"
		return
	if _my_ready:
		_my_ready = false
		NetBus.send_to(1, JSON.stringify({ "type": "arena_unready" }))
		_status.text = "已取消准备，请点击「准备」"
	else:
		_my_ready = true
		NetBus.send_to(1, JSON.stringify({ "type": "arena_ready" }))
		_status.text = "我方已准备，等待主机开始…"
	_refresh_ui()

# 所选卡组队伍小卡预览：与普通模式卡组槽/替补队伍同款一行蜂窝卡
func _refresh_slot_preview() -> void:
	if _preview_host == null or not is_instance_valid(_preview_host):
		return
	for c in _preview_host.get_children():
		_preview_host.remove_child(c)
		c.queue_free()
	_preview_host.custom_minimum_size = Vector2.ZERO
	_preview_host.size = Vector2.ZERO
	if _mode != "normal" or _my_slot <= 0:
		return
	var ids: Array = DeckStore.load_deck(_my_slot)
	if ids.size() == 0:
		return
	var avail: float = get_viewport().get_visible_rect().size.x - 60.0
	var r: float = minf(44.0, maxf(avail / (2.0 + float(maxi(ids.size(), 1) - 1) * 1.5), 16.0))
	var sq3 := sqrt(3.0)
	var col_step := 1.5 * r
	var row_step := sq3 * r
	var total_w := 2.0 * r + float(ids.size() - 1) * col_step
	var total_h := 2.0 * row_step
	_preview_host.custom_minimum_size = Vector2(total_w, total_h)
	_preview_host.size = Vector2(total_w, total_h)
	for i in ids.size():
		var hid := String(ids[i])
		var def := DataRegistry.get_hero(hid)
		if def == null:
			continue
		var cx := r + float(i) * col_step
		var cy := r + (row_step / 2.0 if i % 2 == 1 else 0.0)
		var card := HexCard.new(def, hid, r)
		card.position = Vector2(cx - r, cy - row_step / 2.0)
		card.hovered.connect(_on_hero_hovered)
		_preview_host.add_child(card)

# 悬停属性浮层（与选人页同款：大字、限宽、自动换行）
func _build_hover_tooltip() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_hover_tooltip = PanelContainer.new()
	_hover_tooltip.visible = false
	_hover_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.07, 0.11, 0.96)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	_hover_tooltip.add_theme_stylebox_override("panel", sb)
	layer.add_child(_hover_tooltip)
	_hover_box = VBoxContainer.new()
	_hover_box.add_theme_constant_override("separation", 8)
	_hover_tooltip.add_child(_hover_box)

func _on_hero_hovered(hid: String) -> void:
	if _hover_tooltip == null or not is_instance_valid(_hover_tooltip):
		return
	if hid == "":
		_hover_tooltip.visible = false
		return
	var def := DataRegistry.get_hero(hid)
	if def == null:
		return
	for c in _hover_box.get_children():
		_hover_box.remove_child(c)
		c.queue_free()
	var zones := DataRegistry.hero_info_zones(def)
	for i in zones.size():
		if i > 0:
			var sep := HSeparator.new()
			sep.custom_minimum_size = Vector2(260, 6)
			sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var lnsb := StyleBoxLine.new()
			lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
			lnsb.thickness = 1
			sep.add_theme_stylebox_override("separator", lnsb)
			_hover_box.add_child(sep)
		var lb := Label.new()
		lb.text = zones[i]
		lb.add_theme_font_size_override("font_size", 20)
		lb.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.custom_minimum_size = Vector2(380, 0)
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hover_box.add_child(lb)
	_hover_tooltip.reset_size()
	_hover_tooltip.visible = true

# "编辑卡组"：叠层打开普通模式选人页（网络连接不断、大厅状态保留）。
# 编辑目标 = 当前已选槽（未选则沿用上次槽位），Menu 会自动载入并自动保存。
func _open_deck_editor() -> void:
	if _mode != "normal" or _my_ready:   # 已准备 = 锁定队伍，需先取消准备
		return
	if _my_slot > 0:
		GameState.last_deck_slot = _my_slot
	GameState.net_edit_mode = true
	var menu: Node = (load("res://scenes/Menu.tscn") as PackedScene).instantiate()
	add_child(menu)

# 选人叠层关闭回调（Menu._on_edit_done 调用）：刷新卡组状态与预览
func _on_editor_closed() -> void:
	if NetBus.is_online:
		_status.text = "编辑完成：可点击「准备」通知主机开始。"
	else:
		_status.text = "编辑完成。"
	_refresh_ui()

func _broadcast_mode() -> void:
	if NetBus.is_online:
		NetBus.send_all(JSON.stringify({ "type": "mode", "mode": _mode }))

# 切换到竞技场模式：清空普通模式卡组确认相关状态与提醒（竞技场无需选卡组）
func _enter_arena_mode() -> void:
	_my_confirmed = false
	_my_slot = 0
	_peer_slot = 0
	_peer_deck = []
	_my_ready = false
	_peer_ready = false
	if NetBus.is_host:
		_status.text = "竞技场模式：等待对方点击「准备完毕」…"
	else:
		_status.text = "竞技场模式：请点击「准备完毕」"
	_refresh_ui()

# 切回普通模式：重置准备状态；队伍在"进入对战后"选择，这里可查看/编辑卡组
func _enter_normal_mode() -> void:
	_my_ready = false
	_peer_ready = false
	if _my_slot <= 0:
		_my_slot = 1   # 默认查看槽1
	if NetBus.is_online:
		if NetBus.is_host:
			_status.text = "普通模式：等待对方点击「准备」后即可开始"
		else:
			_status.text = "普通模式：查看/编辑卡组后点击「准备」"
	else:
		_status.text = "普通模式：开房或加入后选择卡组"
	_refresh_ui()

# 选择对战模式：仅主机可改，客户端跟随主机（收到主机的 mode 广播自动同步）。
func _pick_mode(m: String) -> void:
	if not NetBus.is_host:
		_status.text = "模式由主机决定，请等待主机选择。"
		return
	_mode = m
	if _mode == "arena":
		_enter_arena_mode()
	else:
		_enter_normal_mode()
	_broadcast_mode()

func _on_host() -> void:
	_ver_mismatch = false   # 重新开房：清除上次版本不符标记
	# 已开房（作为主机）再点 -> 取消开房，回到空闲
	if NetBus.is_host:
		NetBus.stop()
		_connected_ok = false
		_am_host = false
		_session_started = false   # 主动取消：会话结束，"重新连接"不再可用
		GameState.note_net_room(false, "", 18861, false)
		_status.text = "已取消开房。"
		_refresh_ui()
		return
	# 正在以客户端连接他人 -> 先断开，再开房
	if NetBus.is_online and not NetBus.is_host:
		NetBus.stop()
		_connected_ok = false
	NetBus.host_match(PORT)
	if NetBus.is_host:
		# 端口可能被自动避让换过（默认端口被占时），把实际端口显示出来方便对方填写
		var hint := "已开启主机（端口 %d），等待对方加入…" % NetBus.active_port
		if NetBus.active_port != PORT:
			hint += "（对方请在地址里写 IP:%d）" % NetBus.active_port
		_status.text = hint
		_connecting_sec = 0.0
		_connected_ok = true   # 主机开房即就绪，不参与"连接超时"
		_am_host = true
		_session_started = true
		_auto_retry_done = true   # 主机不做自动重连（等对方重新加入，或自己再开房）
		GameState.note_net_room(true, "", NetBus.active_port, true)
	else:
		_status.text = "开房失败: %s" % NetBus.last_tick_error
	_refresh_ui()

func _on_join() -> void:
	_ver_mismatch = false   # 重新加入：清除上次版本不符标记
	var raw := _ip.text.strip_edges()
	if raw == "":
		_status.text = "请填写主机地址"
		return
	# 地址支持 "IP" 或 "IP:端口"（主机端口被自动换过时用冒号指定）
	var parts := raw.rsplit(":", true, 1)
	var addr: String = raw
	var portv: int = NetBus.DEFAULT_PORT
	if parts.size() == 2 and parts[1].is_valid_int():
		addr = parts[0]
		portv = parts[1].to_int()
	# 正在开房（本地 server 监听中）-> 先停掉，避免端口占用/状态残留
	if NetBus.is_host:
		NetBus.stop()
	_last_join_addr = addr
	_last_join_port = portv
	_am_host = false
	_auto_retry_done = false   # 新的手动加入会话：允许之后断线自动重连一次
	GameState.note_net_room(false, addr, portv, false)   # 记录地址；连上后(note joined)再置可用
	NetBus.join_match(addr, portv)
	if NetBus.is_online and not NetBus.is_host:
		_status.text = "正在连接 %s:%d…" % [addr, portv]
		_connecting_sec = 0.0
		_connected_ok = false   # 等真正连上（_on_connected）后置 true，期间 8s 超时兜底
	else:
		_status.text = "加入失败: %s" % NetBus.last_tick_error
	_refresh_ui()

# 手动"重新连接"：客户端重连上次主机地址；主机则重新开房等待对方
func _on_reconnect() -> void:
	if not _session_started:
		_status.text = "还没有可重连的会话：请先「开房」或「加入」。"
		return
	if NetBus.is_online:
		NetBus.stop()   # 若仍在尝试中，先彻底停掉再重来
		_connected_ok = false
	if _am_host:
		_on_host()   # 主机：重新开房（等对方再加入）
		return
	if _last_join_addr == "":
		_status.text = "没有可重连的主机地址：请手动填写地址后点「加入」。"
		_refresh_ui()
		return
	_ver_mismatch = false
	_auto_retry_done = false   # 手动重连后，若再意外断开仍可自动重连一次
	NetBus.join_match(_last_join_addr, _last_join_port)
	if NetBus.is_online and not NetBus.is_host:
		_status.text = "正在重新连接 %s:%d…" % [_last_join_addr, _last_join_port]
		_connecting_sec = 0.0
		_connected_ok = false
	else:
		_status.text = "重连失败：%s" % NetBus.last_tick_error
	_refresh_ui()

# ---- 历史主机地址（连成功过的地址，持久化到 user://）----
func _load_addrs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(ADDR_SAVE_PATH) != OK:
		return
	var arr: Array = cfg.get_value("net", "addrs", [])
	for a in arr:
		var s := String(a).strip_edges()
		if s != "" and not _addrs.has(s):
			_addrs.append(s)

func _save_addrs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "addrs", _addrs)
	var err := cfg.save(ADDR_SAVE_PATH)
	if err != OK:
		print("历史地址存档跳过（无法写入 user://）: ", err)

# 记一条"连成功过"的地址：最近用的排最前、去重、最多 ADDR_HISTORY_MAX 条
func _remember_addr(disp: String) -> void:
	var s := disp.strip_edges()
	if s == "":
		return
	_addrs.erase(s)
	_addrs.push_front(s)
	while _addrs.size() > ADDR_HISTORY_MAX:
		_addrs.pop_back()
	_save_addrs()
	_refresh_addr_history()

func _refresh_addr_history() -> void:
	if _addr_history == null or not is_instance_valid(_addr_history):
		return
	_addr_history.clear()
	_addr_history.add_item("历史地址（暂无）" if _addrs.is_empty() else "选择历史地址…")
	for a in _addrs:
		_addr_history.add_item(String(a))
	_addr_history.select(0)

# 选中历史地址 -> 直接填进输入框并把光标放到末尾（可接着改端口），同时聚焦便于直接输入
func _on_history_picked(idx: int) -> void:
	if idx <= 0 or idx > _addrs.size():
		return   # 占位项：不填
	_ip.text = String(_addrs[idx - 1])
	_ip.caret_column = _ip.text.length()
	_ip.grab_focus()
	_status.text = "已填入 %s：可直接改端口，或点「加入」。" % _ip.text
	_addr_history.select(0)   # 下拉框回到占位项，方便再选同一条重新填入

func _maybe_start() -> void:
	if _ver_mismatch:
		return   # 版本不一致：禁止开始
	# 主机：两种模式都要等加入方点"准备"（普通模式的队伍改为进战斗后选）
	if NetBus.is_host:
		if _mode == "arena":
			if _peer_ready:
				_btn_start.disabled = false
				_status.text = "对方已准备，可以开始（竞技场选卡）"
		elif _peer_ready:
			_btn_start.disabled = false
			_status.text = "对方已准备，可以开始（进入对战后选择队伍）"

# 返回主菜单：停止网络连接并重置联机状态（避免残留连接/标志影响下次进入）。
func _back_to_menu() -> void:
	NetBus.stop()
	GameState.reset_online()
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

# 主机开战：普通模式不再预先锁定队伍——进战斗后双方各自弹"选择卡组"面板（与单机一致）。
func _on_start() -> void:
	if not NetBus.is_host:
		_status.text = "等待主机开始…"
		return
	GameState.is_online = true
	GameState.is_host = true
	GameState.no_death_limit = false   # 联机正式规则：3 人判负
	GameState.dual_control = false     # 联机不是"自由部署双控"
	GameState.clear_placement()        # 清掉"自由部署(测试)"残留摆放，避免联机沿用沙箱布阵
	GameState.arena_mode = (_mode == "arena")
	# 主机随机生成对局种子并广播：两端 Battle 同种子 -> 障碍/竞技场发牌/先后手确定性一致。
	# 必须先 randomize()：全局 RNG 默认固定序列，不随机化则每局 seed 相同、先后手永远一样。
	randomize()
	var sd := randi()
	GameState.online_seed = sd
	var pdeck := _deck_of(_my_slot)
	var edeck := _peer_deck
	if _mode == "normal":
		# 普通模式：队伍改由"进战斗后选卡组"确定，这里不校验、不带卡组（留空）
		GameState.pick_deck_in_battle = true
		pdeck = []
		edeck = []
	else:
		GameState.pick_deck_in_battle = false
		if pdeck.size() == 0:
			pdeck = ["hero_06", "hero_17", "hero_26"]
		if edeck.size() == 0:
			edeck = ["hero_13", "hero_12", "hero_23"]
	GameState.player_deck = pdeck
	GameState.enemy_deck = edeck
	NetBus.send_all(JSON.stringify({ "type": "start", "mode": _mode, "seed": sd, "pdeck": pdeck, "edeck": edeck }))
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _go_to_match_online() -> void:
	# 棋盘为共享视角（不翻转）：PLAYER 阵营（下方）= 主机卡组 pdeck，ENEMY 阵营（上方）= 客户端卡组 edeck。
	# 两端用同一套卡组：主机操作蓝方、客户端操作红方（敌轮由客户端点击放置）。
	GameState.is_online = true
	GameState.is_host = false
	# 客户端也必须和主机一样清掉"自由部署(测试)"沙箱残留：
	# 带着 dual_control=true 进对局时，主机回合开始会走双控分支——弹"敌方回合（你操控）"，
	# 还会把本端 state 设成 PLAYER_INPUT（主机回合本端能乱动，两端不同步）。
	# no_death_limit / placement 残留同样会让联机按沙箱规则跑（不判 3 人阵亡、沿用沙箱摆放）。
	GameState.dual_control = false
	GameState.no_death_limit = false
	GameState.clear_placement()
	GameState.arena_mode = (_peer_mode == "arena")
	# 普通模式：队伍由进战斗后的"选择卡组"面板确定（与单机一致）
	GameState.pick_deck_in_battle = (_peer_mode == "normal")
	if _last_start.size() > 0:
		GameState.online_seed = int(_last_start.get("seed", 12345))
		GameState.player_deck = _last_start.get("pdeck", [])
		GameState.enemy_deck = _last_start.get("edeck", [])
	else:
		GameState.online_seed = 12345
		GameState.player_deck = ["hero_06", "hero_17", "hero_26"]
		GameState.enemy_deck = ["hero_13", "hero_12", "hero_23"]
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _deck_of(slot: int) -> Array:
	if slot <= 0:
		return []
	return DeckStore.load_deck(slot)

func _refresh_ui() -> void:
	if not is_instance_valid(_mode_label):
		return
	var my_is_host := NetBus.is_host
	# 开房/加入按钮：开房中=可取消；连接对方中=两按钮禁用（防重复触发）
	_btn_host.text = "取消开房" if my_is_host else "开房（作为主机）"
	if NetBus.is_online and not my_is_host:
		# 客户端尝试连接/已连：不可再开房或重复加入（断线由超时或连接断开恢复）
		_btn_host.disabled = true
		_btn_join.disabled = true
	else:
		_btn_host.disabled = false
		_btn_join.disabled = false
	# 重新连接：仅本次会话已建立过(开房/连上)才可用；连接中禁用防重复
	if _btn_reconnect != null:
		_btn_reconnect.disabled = not _session_started or NetBus.is_online
	_mode_label.text = "当前模式: %s%s" % ["普通" if _mode == "normal" else "竞技场", "" if my_is_host else "（主机选择）"]
	for b in _mode_btn:
		var mb: Button = b
		# 仅主机能选择模式；客户端按钮置灰并跟随主机
		mb.disabled = not my_is_host
	# 卡组槽区域仅在"已开房/加入（联网）且当前为普通模式"时显示：
	# 未连接时默认隐藏，开房/加入成功、或房主已开房后点「普通模式」即显示。
	# 注：队伍最终在"进入对战后"选择，这里保留卡组槽/队伍预览与「编辑卡组」，
	# 方便对局前后查看与编辑自己的卡组（「确认卡组」不再是开战前置条件）。
	var show_slots := _mode == "normal" and NetBus.is_online
	if _slot_head != null:
		_slot_head.visible = show_slots
	for b in _slot_btn:
		b.visible = show_slots
	if _deck_info != null:
		_deck_info.visible = show_slots
	if _preview_host != null:
		_preview_host.visible = show_slots
	if _btn_edit != null:
		_btn_edit.visible = show_slots
		_btn_edit.disabled = _my_ready   # 已点「准备」= 锁定队伍：需先「取消准备」才能编辑
	_refresh_slot_preview()
	if _btn_confirm != null:
		_btn_confirm.visible = show_slots
	for i in _slot_btn.size():
		var s: int = SLOTS[i]
		var b: Button = _slot_btn[i]
		b.text = "槽%d" % s
		b.disabled = not (_mode == "normal")   # 准备后仍可切槽"查看"其它卡组（编辑卡组仍锁定）
		if _my_slot == s and _my_confirmed:
			b.text = "槽%d ✓" % s
		elif _my_slot == s:
			b.text = "槽%d\n▲" % s   # 待确认：向上的三角形位于槽号下方
	# 卡组状态文案（阵容以预览小卡展示，这里不重复名单）
	if _deck_info != null:
		if _my_ready and NetBus.is_online and not NetBus.is_host:
			_deck_info.text = "已准备（可切换卡组槽查看；编辑卡组需先取消准备）"
		elif _mode == "normal" and NetBus.is_online and _my_slot > 0:
			var deck := DeckStore.load_deck(_my_slot)
			if deck.size() == 0:
				_deck_info.text = "卡组（槽 %d）：空 —— 点「编辑卡组」选够 %d 名英雄。" % [_my_slot, MIN_PICK]
			elif deck.size() < MIN_PICK:
				_deck_info.text = "卡组（槽 %d）：仅 %d 人（不足 %d）—— 点「编辑卡组」补足。" % [_my_slot, deck.size(), MIN_PICK]
			else:
				_deck_info.text = "卡组（槽 %d）：共 %d 名" % [_my_slot, deck.size()]
		else:
			_deck_info.text = "卡组：未选择"
	# 加入方"准备"（普通模式 / 竞技场通用）：点击后通知主机解锁"开始对局"
	if _btn_ready != null:
		_btn_ready.remove_theme_stylebox_override("normal")
		_btn_ready.remove_theme_stylebox_override("hover")
		_btn_ready.remove_theme_stylebox_override("pressed")
		# 仅加入方显示（主机不需要准备）；普通模式与竞技场通用
		var show_ready := NetBus.is_online and not my_is_host
		_btn_ready.visible = show_ready
		if not show_ready:
			_btn_ready.disabled = true
			_btn_ready.text = "准备"
		elif _my_ready:
			_btn_ready.disabled = false
			_btn_ready.text = "取消准备"
		else:
			_btn_ready.disabled = not NetBus.is_online
			_btn_ready.text = "准备"
			# 【2026-09-20】原来这里给「准备」按钮单独套了一套橙框灰底的 StyleBoxFlat 做"提醒"，
			# 结果它和其它按钮（主题里那款黑色金属牌）长得不一样 —— 用户反馈"样式没同步"。
			# 现在删掉这层自定义样式：准备按钮与全游戏按钮同款，提醒改由上面的状态文字承担。
	# 开始按钮：只有主机能发起对局 —— 加入方（客房）不显示这个按钮，点「准备」等主机开战即可。
	# 与上面的「准备」按钮对称：准备=仅加入方显示，开始=仅主机显示，两者都要求已联网（未联网时都不显示）。
	_btn_start.visible = NetBus.is_online and my_is_host
	# 开始按钮：主机 + 已连接 + 版本一致；两种模式都需"加入方已准备"
	var start_ok := false
	if _ver_mismatch:
		_status.text = "版本不一致，无法开始。请双方使用同一版本的游戏（本机 v%d）。" % NET_VERSION
	elif my_is_host and NetBus.is_online:
		if not _peer_online:
			_status.text = "等待对方加入…"
		elif not _peer_ready:
			_status.text = "等待对方点击「准备」…"
		else:
			start_ok = true
			_status.text = "对方已准备，可以开始（进入对战后选择队伍）"
	_btn_start.disabled = not start_ok
