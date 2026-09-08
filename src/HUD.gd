class_name HUD
extends CanvasLayer
## 战斗界面浮层：显示回合/阵营、消息日志、操作提示，并放置结束回合/重开按钮。

var battle: Battle

var _round_label: Label
var _last_phase_state := -1   # 上次刷新时的 Battle.state（_process 检测阶段切换，补刷新顶部标签）
var _turn_banner: Label = null       # 回合切换中央大字横幅（短暂显示后自动消失）
var _turn_banner_tween: Tween = null
var _flame_icon: Control = null   # 扣血提醒火焰（第11回合起常驻脉动）
var _round_fire_tween: Tween = null   # 回合标签的"燃烧"颜色脉动 tween（第11回合起）
var _turn_timer_label: Label   # 本端回合剩余时间（对局中我方回合显示）
var _result_overlay: Control = null
var _team_panel: PanelContainer = null    # 下方常驻队伍展示（整支卡组，含替补）——替补阶段复用为"选人面板"
var _arena_panel: PanelContainer = null   # 竞技场选人面板（2选1）
var _arena_timer_label: Label = null      # 选人倒计时（选卡面板上方的大字）
var _player_deaths: Label
var _enemy_deaths: Label
var _last_pd := -1
var _last_ed := -1
var _end_btn: Button          # 结束回合（仅我方回合可点）
var _restart_btn: Button      # 重开（联机不需要，隐藏）
var _back_btn: Button         # 返回（联机=返回大厅，单机=返回选人）
var _warn_holder: Control = null   # 回合剩余时间不足警告：屏幕边缘浅红闪烁
var _warn_tween: Tween = null      # 边缘警告呼吸 tween
var _unit_card_overlay: Control = null   # 右键英雄信息卡（成员持有，避免 lambda 捕获被释放节点）
var _notice_overlay: Control = null      # 开局"先手"浮框（短暂显示后自动消失）
var _notice_show_ms := 0                  # 先手提示出现时间（最短展示时间判定用）
const FIRST_NOTICE_MIN_SECONDS := 3.0     # 先手提示在普通模式下最少展示时长（秒）
# 联机快捷喊话:左下角按钮 + 选言面板 + 顶部气泡
var _chat_btn: Button = null
var _chat_panel: PanelContainer = null
var _chat_bubble: PanelContainer = null
var _chat_bubble_tween: Tween = null

func _ready() -> void:
	layer = 50
	_build()

func bind(b: Battle) -> void:
	battle = b
	battle.match_result.connect(show_result)
	battle.sub_select_requested.connect(_refresh_team_panel)   # 替补阶段：同一队伍面板切换为可点选
	battle.sub_placed.connect(_on_sub_placed)
	battle.arena_draft_requested.connect(_show_arena_pair)
	battle.arena_draft_done.connect(_close_arena_panel)
	battle.team_updated.connect(_refresh_team_panel)
	battle.deploy_refresh.connect(_show_deploy_panel)
	battle.first_side_notice.connect(_show_first_side_notice)
	battle.card_view_requested.connect(show_unit_card)
	battle.item_view_requested.connect(show_item_info)
	battle.touch_view_end_requested.connect(_close_unit_card)
	battle.turn_banner.connect(_show_turn_banner)
	battle.peer_message.connect(_show_peer_chat)
	# 用对象方法而非 lambda 连接 autoload 信号：场景释放时 Godot 自动断开连接，
	# 避免"全局信号在对象释放后仍回调其 lambda（Lambda capture freed）"。
	GameState.round_changed.connect(_on_round_changed)
	GameState.active_side_changed.connect(_on_round_changed)

# 右键查看生成物作用
func show_item_info(type: String) -> void:
	_close_unit_card()   # 统一：若已有信息浮层先关闭（复用同一 overlay 槽，避免叠加/自捕获）
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_unit_card_overlay_input)
	add_child(overlay)
	_unit_card_overlay = overlay
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(true)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.18)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_panel(Color(0.12, 0.12, 0.18, 0.92)))
	overlay.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	var title := Label.new()
	title.text = "增益道具"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var desc := Label.new()
	desc.text = battle.item_desc(type)
	desc.add_theme_font_size_override("font_size", 16)
	desc.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(200, 0)
	v.add_child(desc)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 38)
	close.pressed.connect(_close_unit_card)
	v.add_child(close)
	panel.custom_minimum_size = Vector2(220, 0)
	var anchor := get_viewport().get_mouse_position()
	panel.position = anchor
	panel.size = Vector2(220, 0)
	_position_unit_card(overlay, panel, vsize)

# 右键查看卡面：弹出该单位完整信息（出现在点击英雄附近，点面板外关闭）。
# 与其它属性浮层同格式：显示区分区 + 贴左短线 + 四周留白。
func show_unit_card(u: Unit) -> void:
	# 若目标单位已失效（正在消失/被释放），直接忽略，避免访问已释放对象导致崩溃
	if u == null or not is_instance_valid(u):
		return
	# 若已有打开的英雄卡：先关闭旧的（成员持有，避免重复叠加/泄漏）
	_close_unit_card()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 点击面板外任意处即关闭（走成员方法，不捕获被释放节点）
	overlay.gui_input.connect(_on_unit_card_overlay_input)
	add_child(overlay)
	_unit_card_overlay = overlay
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(true)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.18)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击穿透给 overlay 处理关闭
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	var pn := _make_panel(Color(0.12, 0.12, 0.18, 0.92))
	pn.content_margin_left = 12.0
	pn.content_margin_right = 12.0
	pn.content_margin_top = 10.0
	pn.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", pn)
	overlay.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)
	# 显示区①：名字 + 阵营（按本端视角标注：联机客户端操作红方，红方是"我方"）
	var is_my := false
	if battle != null and is_instance_valid(battle):
		is_my = u.faction == battle._my_faction()
	var title := Label.new()
	title.text = "%s  ·  %s" % [u.display_name, "我方" if is_my else "敌方"]
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 名字较长时换行，避免显示不全
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(title)
	# 显示区②：实战属性（HP 现值/上限 + 有效数值 + 状态）
	v.add_child(_make_zone_sep())
	var stats := Label.new()
	# 大骑士移动=直线冲锋任意距离（与选卡界面一致按 ∞ 展示，不显示误导性的数值）
	var move_txt := "%d" % u.effective_move()
	if u.hero_id == "hero_24":
		move_txt = "∞"
	# 坠炮手射程=全场，按 ∞ 展示
	var range_txt := "%d" % u.attack_range
	if u.hero_id == "hero_45":
		range_txt = "∞"
	stats.text = "HP %d/%d   攻击 %d   移动 %s   射程 %s\n状态：%s" % [u.hp, u.max_hp, u.effective_atk(), move_txt, range_txt, _status_text(u)]
	stats.add_theme_font_size_override("font_size", 17)
	stats.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.custom_minimum_size = Vector2(270, 0)   # 限制换行宽度，避免撑满全屏
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(stats)
	var def := DataRegistry.get_hero(u.hero_id)
	if def != null:
		# 显示区③：技能描述（清洗后，不含识别标签残留）
		var desc := DataRegistry.clean_skill_desc(def.desc)
		if desc != "":
			v.add_child(_make_zone_sep())
			var skill := Label.new()
			skill.text = "技能\n%s" % desc
			skill.add_theme_font_size_override("font_size", 16)
			skill.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0))
			skill.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			skill.custom_minimum_size = Vector2(270, 0)
			skill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(skill)
		# 显示区④：词条解释
		var kw := _keyword_lines(u)
		if kw.size() > 0:
			v.add_child(_make_zone_sep())
			var kw_label := Label.new()
			kw_label.text = "\n".join(kw)
			kw_label.add_theme_font_size_override("font_size", 16)
			kw_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.6))
			kw_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			kw_label.custom_minimum_size = Vector2(270, 0)
			kw_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(kw_label)
	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(0, 40)
	close.pressed.connect(_close_unit_card)
	v.add_child(close)
	panel.custom_minimum_size = Vector2(300, 0)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# 先放好，下一帧用成员面板引用做屏内收敛（避免 tween/lambda 捕获被释放节点）
	panel.position = get_viewport().get_mouse_position()
	panel.size = Vector2(300, 0)
	_position_unit_card(overlay, panel, vsize)

func _close_unit_card() -> void:
	if _unit_card_overlay != null and is_instance_valid(_unit_card_overlay):
		_unit_card_overlay.queue_free()
		_unit_card_overlay = null
	if battle != null and is_instance_valid(battle):
		battle.set_unit_card_open(false)

# 回合切换横幅：屏幕中央弹出大字号提示（"你的回合"/"敌方回合"），放大浮现、短暂停留后淡出。
# 仅视觉层，不拦截任何输入（鼠标/触摸照常操作棋盘）。
func _show_turn_banner(text: String) -> void:
	if _turn_banner_tween != null and _turn_banner_tween.is_valid():
		_turn_banner_tween.kill()
	if _turn_banner != null and is_instance_valid(_turn_banner):
		_turn_banner.queue_free()
	var vs := get_viewport().get_visible_rect().size
	var label := Label.new()
	label.name = "TurnBanner"
	label.text = text
	label.add_theme_font_size_override("font_size", 54)
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 8)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不拦截点击
	add_child(label)
	_turn_banner = label
	var t := create_tween()
	_turn_banner_tween = t
	label.modulate.a = 0.0
	label.scale = Vector2(1.4, 1.4)
	label.pivot_offset = vs / 2.0
	# 放大+淡入 → 停留 → 淡出并移除
	t.tween_property(label, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.parallel().tween_property(label, "modulate:a", 1.0, 0.16)
	t.tween_interval(0.9)
	t.tween_property(label, "modulate:a", 0.0, 0.35)
	t.tween_callback(func():
		if is_instance_valid(label):
			label.queue_free()
		if _turn_banner == label:
			_turn_banner = null)

# 点面板外任意处关闭浮层。返回 true 表示本次事件已消费（阻止漏给 Battle 触发重复查看/行动）
func _on_unit_card_overlay_input(ev: InputEvent) -> bool:
	var close_now := false
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		# 鼠标/触摸统一：按下或（触屏）抬起都关闭
		close_now = mb.pressed or DisplayServer.is_touchscreen_available()
	elif ev is InputEventScreenTouch:
		close_now = true   # 触摸事件（未模拟成鼠标时）同样关闭
	if close_now:
		var card_ctl := _unit_card_overlay
		_close_unit_card()
		if card_ctl != null and is_instance_valid(card_ctl):
			card_ctl.accept_event()   # 关键：消费事件，阻止其继续漏给 Battle 的触摸手势
		return true
	return false

# 等 PanelContainer 完成布局后按内容尺寸定位并收敛到屏内（overlay/panel 由成员引用，安全判空）
func _position_unit_card(overlay: Control, panel: PanelContainer, vsize: Vector2) -> void:
	var wait := get_tree().create_timer(0.05)
	await wait.timeout
	if overlay == null or panel == null or not is_instance_valid(overlay) or not is_instance_valid(panel):
		return   # 卡片已被关闭：安全退出
	var anchor := get_viewport().get_mouse_position()
	var msz := panel.get_combined_minimum_size()
	panel.size = Vector2(maxf(msz.x, 300.0), msz.y)
	var pw := panel.size.x
	var ph := panel.size.y
	var px := anchor.x + 24
	var py := anchor.y + 16
	if px + pw > vsize.x - 8:
		px = anchor.x - pw - 24
	if py + ph > vsize.y - 8:
		py = anchor.y - ph - 16
	px = clampf(px, 8, maxf(8, vsize.x - pw - 8))
	py = clampf(py, 8, maxf(8, vsize.y - ph - 8))
	panel.position = Vector2(px, py)

func _keyword_lines(u: Unit) -> Array:
	var lines: Array = DataRegistry.keyword_lines(u.skills, u.attack_type)
	# 技能正文里 [方括号] 状态词（沉默/重伤/猛毒…）也补上解释
	var def := DataRegistry.get_hero(u.hero_id)
	if def != null:
		lines.append_array(DataRegistry.desc_status_lines(def.desc))
	return lines

func _status_text(u: Unit) -> String:
	var s := ""
	if u.has_status("poison"): s += "猛毒 "
	if u.has_status("heavy"): s += "重伤 "
	if u.has_status("atkdown"): s += "麻痹 "
	if u.has_status("freeze"): s += "冰冻 "
	if u.has_status("silence"): s += "沉默 "
	if u.has_status("stun"): s += "眩晕 "
	if u.has_status("possess"): s += "附体 "
	if u.has_status("shield"): s += "圣盾 "
	return s if s != "" else "无"

# 开局"谁先手"提示：常驻悬浮，直到"部署选人面板出现"（部署选人阶段开始）才淡出收起。
# 点一下提示框也可提前关闭；浮框不拦截棋盘操作。
func _show_first_side_notice(text: String) -> void:
	_refresh_round()   # 提示时已进入部署/选人态：顶部立即显示"部署选人/竞技场选人"
	_close_first_notice()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	_notice_overlay = overlay
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.16, 0.92)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.set_border_width_all(1)
	sb.border_color = Color(1.0, 0.85, 0.5)
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	box.add_theme_stylebox_override("panel", sb)
	box.mouse_filter = Control.MOUSE_FILTER_STOP   # 框体可点击关闭，但不挡棋盘
	box.gui_input.connect(_on_first_notice_input)
	overlay.add_child(box)
	var bw := minf(vsize.x - 120, 420)
	box.size = Vector2(bw, 0)
	box.position = Vector2((vsize.x - bw) / 2.0, vsize.y * 0.22)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.55))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	_notice_show_ms = Time.get_ticks_msec()   # 记录出现时刻：普通模式至少展示 FIRST_NOTICE_MIN_SECONDS

# 先手提示淡出收起（仅当仍存在时执行）
func _fade_close_first_notice() -> void:
	if _notice_overlay != null and is_instance_valid(_notice_overlay):
		var ov: Control = _notice_overlay
		var tw2 := ov.create_tween()
		tw2.tween_property(ov, "modulate:a", 0.0, 0.2)
		tw2.tween_callback(_close_first_notice)

func _deploy_panel_shown_notice_gone() -> void:
	# 部署选人面板已出现 = 阶段开始；但先手提示至少要展示满最短时长，没看够就延后收起
	if _notice_overlay == null or not is_instance_valid(_notice_overlay):
		return
	var elapsed := float(Time.get_ticks_msec() - _notice_show_ms) / 1000.0
	if elapsed >= FIRST_NOTICE_MIN_SECONDS:
		_fade_close_first_notice()
	else:
		var wait := FIRST_NOTICE_MIN_SECONDS - elapsed
		var timer := get_tree().create_timer(wait)
		timer.timeout.connect(_fade_close_first_notice)

func _on_first_notice_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		_close_first_notice()

func _close_first_notice() -> void:
	if _notice_overlay != null and is_instance_valid(_notice_overlay):
		_notice_overlay.queue_free()
	_notice_overlay = null

# 开局部署面板（分步：点选英雄 -> 点击出生格放置）
var _deploy_overlay: Control = null
var _deploy_timer_label: Label = null   # 部署轮倒计时（面板上方大字，与竞技场选人一致）
func _show_deploy_panel() -> void:
	_refresh_round()   # 进入/退出部署阶段都刷新顶部标签（部署期显示"部署选人"）
	# 非部署阶段则收起
	if battle.state != Battle.State.DEPLOY and battle.state != Battle.State.PLACE_DEPLOY:
		_close_deploy_panel()
		return
	_close_team_panel()   # 部署期只用"开局选人"面板，与常驻"替补队伍"面板互斥，避免重叠
	if _deploy_overlay:
		_deploy_overlay.queue_free()
	_deploy_overlay = null
	_deploy_timer_label = null
	var vsize := get_viewport().get_visible_rect().size
	# 棋盘下方队伍列表：透明背景、一行六边形卡（与替补面板一致），不弹窗不遮罩
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	_deploy_overlay = overlay
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)   # 透明
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(panel)
	var wrapbox := VBoxContainer.new()
	wrapbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapbox.add_theme_constant_override("separation", 2)
	panel.add_child(wrapbox)
	var title := Label.new()
	var placing := battle.state == Battle.State.PLACE_DEPLOY
	# 当前轮是否轮到本端部署选人
	var my_pick := _deploy_my_pick()
	var side_txt := ""
	if placing:
		side_txt = "点击我方出生格放置"
	elif my_pick:
		side_txt = "点选英雄部署"
	else:
		side_txt = "等待对方选择中…"
	# 下方始终显示本端"我方"的英雄/卡池（不随对方轮切换成对方的英雄）
	title.text = "开局选人 · %s · 我方 %d/%d  对方 %d/%d" % [
		side_txt,
		battle._my_deployed_count(), Battle.DEPLOY_COUNT_BATTLE,
		battle._opp_deployed_count(), Battle.DEPLOY_COUNT_BATTLE,
	]
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapbox.add_child(title)
	# 卡池：始终为本端"我方"部署卡池；轮到本端才可点选
	var ids: Array = battle._my_deploy_pool()
	var sel := battle._pending_deploy
	if battle._my_faction() == DataRegistry.Faction.ENEMY:
		sel = battle._pending_enemy_deploy
	var pool := _make_hex_pool(ids, _on_deploy_hover, _on_deploy_click, not my_pick or placing, sel, true, 48.0)
	wrapbox.add_child(pool)
	var pw: float = pool.custom_minimum_size.x + 20.0
	var ph: float = pool.custom_minimum_size.y + 34.0
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 放在屏底（按钮行下方空区）：避免遮住放大后的棋盘
	panel.position = Vector2((vsize.x - pw) / 2.0, vsize.y - ph - 76)
	# 倒计时大字放按钮行上方（棋盘不遮挡时居中感不变）
	var tlabel := Label.new()
	tlabel.add_theme_font_size_override("font_size", 48)
	tlabel.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	tlabel.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	tlabel.add_theme_constant_override("outline_size", 6)
	tlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tlabel.visible = false
	tlabel.position = Vector2(panel.position.x, panel.position.y - 66)
	tlabel.size = Vector2(pw, 60)
	overlay.add_child(tlabel)
	_deploy_timer_label = tlabel
	# 部署选人面板已出现 = 阶段开始：先手提示此刻收起（若有）
	_deploy_panel_shown_notice_gone()

# 本端当前轮是否轮到本端部署选人（主机=玩家轮，客户端=敌轮；单机=仅玩家轮）
func _deploy_my_pick() -> bool:
	if not GameState.is_online:
		return battle._deploy_side == 0   # 单机：仅玩家轮本端点，敌轮 AI 自动
	return battle._deploy_side == battle._my_side()

func _on_deploy_hover(hid: String) -> void:
	if hid == "":
		_set_score_tooltip_visible(false)
		return
	_set_score_tooltip_hero(hid)

# 统一的六边形卡池（开局选人/替补共用，保证样式一致）
func _make_hex_pool(ids: Array, on_hover: Callable, on_click: Callable, disabled: bool = false, selected_id: String = "", single_row: bool = false, card_radius: float = 38.0) -> Control:
	var host := Control.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 宿主不拦截鼠标，卡牌各自响应
	var r := card_radius
	var col_step := 1.5 * r           # 平顶：列中心横向间距
	var row_step := sqrt(3.0) * r     # 平顶：行中心纵向间距
	var cols := ids.size() if single_row else 4
	var rows := 1 if single_row else int(ceil(float(ids.size()) / float(cols)))
	if rows < 1:
		rows = 1
	var total_w := 2.0 * r + float(cols - 1) * col_step
	var total_h := row_step * float(rows) + row_step
	host.custom_minimum_size = Vector2(total_w, total_h)
	host.size = Vector2(total_w, total_h)
	for i in ids.size():
		var hid: String = ids[i]
		var def := DataRegistry.get_hero(hid)
		var col := i
		var row := 0
		if not single_row:
			col = int(i / float(rows))
			row = i % rows
		var cx := r + float(col) * col_step
		var cy := r + float(row) * row_step + (row_step / 2.0 if col % 2 == 1 else 0.0)
		var card := HexCard.new(def, hid, r)
		card.position = Vector2(cx - r, cy - row_step / 2.0)
		card.disabled_draw = disabled
		card.selected = (hid == selected_id)
		card.hovered.connect(on_hover)
		card.clicked.connect(on_click)
		host.add_child(card)
	return host

func _on_deploy_click(hid: String) -> void:
	if not _deploy_my_pick():
		return   # 非本端点选轮（联机等待对端/单机敌轮AI）不响应
	if battle._my_faction() == DataRegistry.Faction.PLAYER:
		if battle.state == Battle.State.DEPLOY:
			battle._on_deploy_pick(hid)
		elif battle.state == Battle.State.PLACE_DEPLOY:
			# 放位阶段：再次点英雄可反悔/切换
			battle._on_deploy_pick_again(hid)
	else:
		if battle.state == Battle.State.DEPLOY:
			battle._on_enemy_deploy_pick(hid)
		elif battle.state == Battle.State.PLACE_DEPLOY:
			battle._on_enemy_deploy_pick_again(hid)
	_show_deploy_panel()

var _score_tooltip_wrap: PanelContainer = null   # 属性浮层面板（带背景，显示/隐藏及定位用）
var _score_tooltip_box: VBoxContainer = null     # 浮层内容（各显示区 + 短线）
var _tooltip_pin_rect := Rect2()                 # 非空=浮层固定到该矩形上方（触屏查看，避免手指遮挡）；空=跟随鼠标

# 竞技场选人触屏手势（安卓/iOS）：短按确认；长按查看；按住滑动切换查看卡；松手不确认。
var _arena_confirm_cb: Callable = Callable()   # 本轮竞技场选人确认回调（短按触发，触屏用手势层复用它）
var _arena_card_centers := {}    # hid -> 卡中心（层/宿主坐标系，命中判定用）
var _arena_touch_active := false
var _arena_touch_down_ms := 0
var _arena_touch_down_pos := Vector2.ZERO   # 按下起点（滑动判定）
var _arena_touch_id := ""          # 当前手指所在/查看的英雄
var _arena_touch_held := false     # 已判定长按查看（松手不确认）
var _arena_touch_moved := false    # 已滑动（抬起不确认）
var _arena_gesture_layer: Control = null   # 触屏手势拦截层（竞技场两张卡上）

# 贴左短分行线（属性弹框各显示区之间的分隔短线）
func _make_zone_sep() -> HSeparator:
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(260, 6)
	sep.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var lnsb := StyleBoxLine.new()
	lnsb.color = Color(1.0, 0.85, 0.5, 0.3)
	lnsb.thickness = 1
	sep.add_theme_stylebox_override("separator", lnsb)
	return sep

# 显示区文字标签（各弹框共用：自动换行、限宽）
func _make_zone_label(text: String, font_size: int, color: Color, min_w: float) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", color)
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.custom_minimum_size = Vector2(min_w, 0)
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return lb

# 悬停详情浮层（挂在 HUD 自身，不遮罩棋盘）：与主菜单属性表同格式——
# 显示区分区 + 贴左短线分行 + 四周留白。单例复用（避免每次重建压到被面板盖住、且泄漏）。
func _ensure_score_tooltip() -> PanelContainer:
	if _score_tooltip_wrap != null and is_instance_valid(_score_tooltip_wrap):
		return _score_tooltip_wrap
	var wrap_box := PanelContainer.new()
	wrap_box.visible = false
	wrap_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _make_panel(Color(0.07, 0.07, 0.11, 0.96))
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	wrap_box.add_theme_stylebox_override("panel", sb)
	wrap_box.z_index = 100   # 置于最顶，避免被下方队伍面板盖住
	add_child(wrap_box)
	_score_tooltip_wrap = wrap_box
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	wrap_box.add_child(box)
	_score_tooltip_box = box
	return wrap_box

# 按显示区重建悬停浮层内容（先清空旧区再重建，避免残留上一英雄的尺寸）
func _set_score_tooltip_zones(zones: Array) -> void:
	var wrap_box := _ensure_score_tooltip()
	for c in _score_tooltip_box.get_children():
		_score_tooltip_box.remove_child(c)
		c.queue_free()
	for i in zones.size():
		if i > 0:
			_score_tooltip_box.add_child(_make_zone_sep())
		var lb := _make_zone_label(zones[i], 20, Color(0.9, 0.93, 1.0), 380.0)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_score_tooltip_box.add_child(lb)
	wrap_box.reset_size()   # 无容器重排：显式收敛到新内容的最小尺寸
	wrap_box.visible = true

# 悬停某英雄：按 DataRegistry 统一区格式显示其属性
func _set_score_tooltip_hero(hid: String) -> void:
	var def := DataRegistry.get_hero(hid)
	if def == null:
		return
	_set_score_tooltip_zones(DataRegistry.hero_info_zones(def))

# 属性浮层统一显隐（作用于带背景的 wrap 本身；仅设内层 Label.visible 会让 wrap 仍隐藏、位置也不收敛）
func _set_score_tooltip_visible(v: bool) -> void:
	if _score_tooltip_wrap and is_instance_valid(_score_tooltip_wrap):
		_score_tooltip_wrap.visible = v

# 替补落位成功：刷新队伍面板回只读态（连续替补会再次走 sub_select_requested 变回可选态）
func _on_sub_placed() -> void:
	_refresh_team_panel()

# 关闭开局部署面板（若有残留，防止旧面板盖在新流程上）
func _close_deploy_panel() -> void:
	if _deploy_overlay:
		_deploy_overlay.queue_free()
		_deploy_overlay = null
		_deploy_timer_label = null

# 竞技场选人：面板中央展示本轮随机的 2 名英雄（2选1），点击即选择
func _show_arena_pair(pair: Array) -> void:
	_refresh_round()   # 进入竞技场选人：顶部标签显示"竞技场选人"
	_close_arena_panel()
	_close_deploy_panel()   # 进入选人：收掉可能残留的上一局部署面板
	var vsize := get_viewport().get_visible_rect().size
	# 大号六边形卡，画面正中、两卡同高且给下方留"飞入队伍"空间；透明背景只显示卡牌
	var card_r := 92.0
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)
	_arena_panel = panel
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 10)
	panel.add_child(wrapbox)
	if pair.size() < 2:
		# 对方选择中 / 联机等待对方完成：显示等待提示（不可点击）
		var wait := Label.new()
		wait.text = "等待对方完成选卡……" if GameState.is_online else "敌方正在选择英雄……"
		wait.add_theme_font_size_override("font_size", 24)
		wait.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55))
		wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wrapbox.add_child(wait)
		panel.custom_minimum_size = Vector2(420, 120)
		panel.size = Vector2(420, 120)
		panel.position = Vector2((vsize.x - 420) / 2.0, (vsize.y - 120) / 2.0)
		return
	# 倒计时（选卡上方大字）：剩余秒数由 Battle 每帧递减，超时自动选第 1 张
	var timer := Label.new()
	timer.add_theme_font_size_override("font_size", 52)
	timer.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	timer.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	timer.add_theme_constant_override("outline_size", 6)
	timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer.text = ""
	wrapbox.add_child(timer)
	_arena_timer_label = timer
	# 手动摆放两张六边形卡：无文字、同高、居中、中间留 gap（不放 _make_hex_pool，避免错位/贴靠）
	var gap := 40.0
	var card_w := card_r * 2.0
	var card_h := sqrt(3.0) * card_r
	var total_w := card_w * 2 + gap
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.custom_minimum_size = Vector2(total_w, card_h)
	host.size = Vector2(total_w, card_h)
	wrapbox.add_child(host)
	var click_cb := func(hid: String):
		# 点击即停表：选中动画期间不再倒计时，防止演出中触发自动选导致双选
		if battle != null and is_instance_valid(battle):
			battle.arena_pick_time_left = -1.0
		# 选中动画：被点卡牌向下移出（飞入下方玩家队伍），未被选的另一张（归敌方）向上移出，
		# 两卡同时播完后再进入下一轮。
		var card := _find_arena_card(hid)
		# 给敌方的那张 = pair 中不是 hid 的另一张
		var enemy_card: Control = null
		for phid in pair:
			if phid != hid:
				enemy_card = _find_arena_card(phid)
				break
		if card == null:
			battle._on_arena_pick(hid)
			return
		var t := create_tween()
		# 玩家选的：向下飞入玩家队伍
		t.tween_property(card, "position", card.position + Vector2(0, 360), 0.45)
		t.parallel().tween_property(card, "modulate:a", 0.0, 0.45)
		# 给敌方的：向上飞出敌方区域
		if enemy_card != null:
			t.parallel().tween_property(enemy_card, "position", enemy_card.position + Vector2(0, -360), 0.45)
			t.parallel().tween_property(enemy_card, "modulate:a", 0.0, 0.45)
		t.tween_callback(func():
			if battle != null and is_instance_valid(battle):
				battle._on_arena_pick(hid))
	for i in pair.size():
		var hid: String = pair[i]
		var def := DataRegistry.get_hero(hid)
		var card := HexCard.new(def, hid, card_r)
		# 同高（y=0），水平居中摆放，间距 gap
		card.position = Vector2(float(i) * (card_w + gap), 0)
		card.hovered.connect(func(hid2: String):
			if hid2 == "":
				_set_score_tooltip_visible(false)
				return
			if DataRegistry.get_hero(hid2) == null:
				return
			_set_score_tooltip_hero(hid2))
		card.clicked.connect(click_cb)
		host.add_child(card)
	# 触屏（安卓/iOS）：竞技场选人 = 短按确认、长按查看、按住滑动切换查看、松手不确认。
	# 桌面保留 HexCard 自身的 hover 查看 + 点击确认。
	if DisplayServer.is_touchscreen_available():
		_setup_arena_touch(pair, host, card_r, click_cb)
	var pw := total_w + 40.0
	var ph := card_h + 40.0 + 78.0   # 预留顶部大字倒计时空间
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 画面正中央（略偏上，给下方飞入路径留空间）
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0 - 40)

# 竞技场触屏（安卓/iOS）：短按=确认选择；按住超时=查看属性；按住滑动=切换查看另一卡；
# 长按/滑动后松手均不确认（属性浮层固定显示在卡上方，不跟随手指）。
# 桌面不用本层：HexCard 自身 hover 查看 + 点击确认。
func _setup_arena_touch(pair: Array, host: Control, card_r: float, confirm: Callable) -> void:
	var gesture := Control.new()
	gesture.name = "ArenaTouchLayer"
	gesture.mouse_filter = Control.MOUSE_FILTER_STOP
	gesture.custom_minimum_size = host.size
	gesture.size = host.size
	gesture.gui_input.connect(_on_arena_touch_gui)
	host.add_child(gesture)   # 后加 → 位于两卡之上，拦截全部点击
	_arena_gesture_layer = gesture
	_arena_confirm_cb = confirm
	# 记录两张卡在层坐标系中的中心（层与 host 同位），供命中判定
	_arena_card_centers.clear()
	for i in pair.size():
		var hid: String = pair[i]
		var cx := float(i) * (card_r * 2.0 + 40.0) + card_r
		var cy := sqrt(3.0) * card_r / 2.0
		_arena_card_centers[hid] = Vector2(cx, cy)
	# 触屏下卡片自身不响应（hover/click 由拦截层接管）
	for c in host.find_children("*", "HexCard", true, false):
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arena_touch_active = false
	_arena_touch_held = false
	_arena_touch_moved = false
	_arena_touch_id = ""

func _on_arena_touch_gui(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion or ev is InputEventScreenDrag:
		# 手指/鼠标按住移动：若已进入查看则跟随切换；否则超阈值视为滑动（不再确认）
		if not _arena_touch_active:
			return
		var pos := (ev as InputEventMouseMotion).position if ev is InputEventMouseMotion else (ev as InputEventScreenDrag).position
		if _arena_touch_down_pos.distance_to(pos) > 20.0:
			_arena_touch_moved = true
		if _arena_touch_held:
			var hid := _arena_hit_card(pos)
			if hid != "" and hid != _arena_touch_id:
				_arena_touch_id = hid
				_show_arena_view(hid)
		return
	var mb := ev as InputEventMouseButton
	var st := ev as InputEventScreenTouch
	if mb != null and mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if (ev is InputEventMouseButton and mb.pressed) or (st != null and st.pressed):
		# 按下：记录起点与时间。倒计时不暂停——长按查看期间正常走秒，不消失也不重置
		_arena_touch_down_ms = Time.get_ticks_msec()
		_arena_touch_down_pos = mb.position if mb != null else st.position
		_arena_touch_active = true
		_arena_touch_moved = false
		_arena_touch_held = false
		_arena_touch_id = _arena_hit_card(_arena_touch_down_pos)
		return
	# 抬起：松开位置落在某张卡上 -> 选择该英雄（含长按查看后手指仍停在卡上松开）
	# 否则（滑到空白处松开 / 未落在卡上）只收起浮层，不选择
	if not _arena_touch_active:
		return
	_arena_touch_active = false
	var up_pos := mb.position if mb != null else (st.position if st != null else _arena_touch_down_pos)
	var up_hid := _arena_hit_card(up_pos)
	_hide_arena_view()
	if up_hid != "" and _arena_confirm_cb.is_valid():
		_arena_confirm_cb.call(up_hid)

# 按住不动超时 → 长按查看（仅竞技场选人且存在手势层时）
func _update_arena_touch_hold() -> void:
	if _arena_gesture_layer == null or not is_instance_valid(_arena_gesture_layer):
		return
	if not _arena_touch_active or _arena_touch_held:
		return
	if Time.get_ticks_msec() - _arena_touch_down_ms < 250:
		return
	_arena_touch_held = true
	if _arena_touch_id != "":
		_show_arena_view(_arena_touch_id)

# 命中判定：点落在某张卡的外接圆内即视为该卡
func _arena_hit_card(pos: Vector2) -> String:
	for hid in _arena_card_centers.keys():
		if _arena_card_centers[hid].distance_to(pos) <= 88.0:
			return hid
	return ""

# 触屏查看某张卡：属性浮层固定显示在该卡上方（不跟随手指）
func _show_arena_view(hid: String) -> void:
	var def := DataRegistry.get_hero(hid)
	if def == null:
		return
	_set_score_tooltip_hero(hid)
	var card := _find_arena_card(hid)
	if card != null and is_instance_valid(card):
		_tooltip_pin_rect = card.get_global_rect()
	_set_score_tooltip_visible(true)

func _hide_arena_view() -> void:
	_tooltip_pin_rect = Rect2()
	_set_score_tooltip_visible(false)

# 在竞技场面板里按 hero_id 找对应 HexCard
func _find_arena_card(hid: String) -> Control:
	if _arena_panel == null:
		return null
	for c in _arena_panel.find_children("*", "HexCard", true, false):
		if c.hero_id == hid:
			return c
	return null

# 关闭竞技场选人面板
func _close_arena_panel() -> void:
	if _arena_panel:
		_arena_panel.queue_free()
		_arena_panel = null
	_arena_timer_label = null
	_arena_gesture_layer = null
	_arena_confirm_cb = Callable()
	_arena_card_centers.clear()
	_arena_touch_active = false
	_arena_touch_held = false
	_arena_touch_moved = false
	_arena_touch_id = ""
	_hide_arena_view()

# 下方常驻队伍面板：整支卡组（上阵 + 替补），一字行透明卡牌，随 team_updated 刷新。
# 同一面板双模式（避免"替补选人面板"与常驻面板重叠/互相遮盖）：
#  - 平时：只读展示本端替补席/队伍，悬停查看属性；
#  - SUBSTITUTING / PLACE_SUB：同一面板变"选择替补上阵"，点击英雄=选中落位（battle._on_sub_pick）。
func _refresh_team_panel() -> void:
	if battle == null:
		return
	# 部署期：只显示"开局选人"面板，不显示下方常驻面板（避免重叠）
	if battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY:
		_close_team_panel()
		return
	var picking := battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB
	if _team_panel:
		_team_panel.queue_free()
		_team_panel = null
	# 替补选中阶段展示当前替补席；平时展示整队（含替补）
	var ids: Array = battle._sub_roster() if picking else battle._player_team_ids()
	if ids.size() == 0:
		return
	var vsize := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	# 透明背景（不遮界面），仅承载卡牌；布局（VBox + 标题 + 一行卡）
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	_team_panel = panel
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 4)
	wrapbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(wrapbox)
	var title := Label.new()
	title.text = "选择替补上阵（点击英雄选中，再点击棋盘绿格落位）" if picking else "替补队伍"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5) if picking else Color(0.6, 0.85, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(title)
	# 悬停显示英雄属性（带背景浮层，位置由 _process 收敛)
	var hover_cb := func(hid: String):
		if hid == "":
			_set_score_tooltip_visible(false)
			return
		_set_score_tooltip_hero(hid)
	var click_cb := func(_h: String):
		pass
	if picking:
		click_cb = func(hid: String):
			battle._on_sub_pick(hid)   # 点击替补英雄：选中并进入落位阶段
			_refresh_team_panel()      # 立即刷新高亮（_pending_sub），后续动作仍可再点其他英雄
	var pool := _make_hex_pool(ids, hover_cb, click_cb, false, battle._pending_sub if picking else "", true, 48.0)
	wrapbox.add_child(pool)
	var pw := pool.custom_minimum_size.x + 20.0
	var ph := pool.custom_minimum_size.y + 34.0
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 放在按钮行上方（按钮行贴屏底），避免遮住棋盘
	panel.position = Vector2((vsize.x - pw) / 2.0, vsize.y - ph - 76)

# 关闭常驻队伍面板
func _close_team_panel() -> void:
	if _team_panel:
		_team_panel.queue_free()
		_team_panel = null
	_close_chat_panel()   # 阶段切换/重开时收起喊话选言面板

func _build() -> void:
	var vsize := get_viewport().get_visible_rect().size
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# 顶部：回合与阵营
	var top := PanelContainer.new()
	top.position = Vector2(0, 0)
	top.size = Vector2(vsize.x, 54)
	top.add_theme_stylebox_override("panel", _make_panel(Color(0.08, 0.08, 0.12, 0.85)))
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	var toph := HBoxContainer.new()
	toph.position = Vector2(0, 0)
	toph.size = Vector2(vsize.x, 54)
	toph.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(toph)
	_round_label = Label.new()
	_round_label.add_theme_font_size_override("font_size", 24)
	_round_label.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toph.add_child(_round_label)
	var flame := FlameIcon.new()
	flame.custom_minimum_size = Vector2(34, 34)
	flame.size = Vector2(34, 34)
	flame.size_px = 26.0
	flame.visible = false   # 第 11 回合起才显示
	toph.add_child(flame)
	_flame_icon = flame
	_turn_timer_label = Label.new()
	_turn_timer_label.add_theme_font_size_override("font_size", 26)
	_turn_timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	_turn_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_turn_timer_label.add_theme_constant_override("outline_size", 3)
	_turn_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_turn_timer_label.visible = false
	toph.add_child(_turn_timer_label)

	# 顶部阵亡计数：左我方 / 右敌方（骷髅图标，放大版）
	_player_deaths = Label.new()
	_player_deaths.add_theme_font_size_override("font_size", 27)
	_player_deaths.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
	_player_deaths.text = "我方 ☠☠☠"
	_player_deaths.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_deaths.position = Vector2(12, 11)
	root.add_child(_player_deaths)
	_enemy_deaths = Label.new()
	_enemy_deaths.add_theme_font_size_override("font_size", 27)
	_enemy_deaths.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	_enemy_deaths.text = "☠☠☠ 敌方"
	_enemy_deaths.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_enemy_deaths.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_enemy_deaths.size = Vector2(vsize.x - 12, 32)
	_enemy_deaths.position = Vector2(0, 11)
	root.add_child(_enemy_deaths)
	_refresh_deaths()

	# 按钮：结束回合 / 重开 / 返回选人（用明确的绝对坐标放置，避免锚点+坐标混搭导致错位）
	var btn_row := HBoxContainer.new()
	btn_row.position = Vector2((vsize.x - 390) / 2.0, vsize.y - 56 - 10)
	btn_row.size = Vector2(390, 56)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	root.add_child(btn_row)

	var end_btn := Button.new()
	end_btn.text = "结束回合"
	end_btn.custom_minimum_size = Vector2(190, 52)
	end_btn.add_theme_font_size_override("font_size", 19)
	var end_sb := StyleBoxFlat.new()
	end_sb.bg_color = Color(0.75, 0.55, 0.15, 1.0)
	end_sb.corner_radius_top_left = 12
	end_sb.corner_radius_top_right = 12
	end_sb.corner_radius_bottom_left = 12
	end_sb.corner_radius_bottom_right = 12
	end_sb.set_border_width_all(2)
	end_sb.border_color = Color(1.0, 0.9, 0.5)
	end_btn.add_theme_stylebox_override("normal", end_sb)
	end_btn.add_theme_color_override("font_color", Color(0.1, 0.08, 0.02))
	end_btn.pressed.connect(_on_end_turn)
	btn_row.add_child(end_btn)
	_end_btn = end_btn

	var restart_btn := Button.new()
	restart_btn.text = "重开"
	restart_btn.custom_minimum_size = Vector2(70, 52)
	restart_btn.add_theme_font_size_override("font_size", 15)
	restart_btn.pressed.connect(_on_restart)
	btn_row.add_child(restart_btn)
	_restart_btn = restart_btn

	var back_btn := Button.new()
	back_btn.text = "返回选人"
	back_btn.custom_minimum_size = Vector2(90, 52)
	back_btn.add_theme_font_size_override("font_size", 15)
	back_btn.pressed.connect(_on_back_to_menu)
	btn_row.add_child(back_btn)
	_back_btn = back_btn

	_set_round_text(1, true)
	_refresh_controls()
	_build_edge_warning(root, vsize)

	# 右下角音效音量调节（喇叭按钮 + 滑条弹层）：与左下角喊话按钮同底线对称；
	# 按钮贴近屏底，弹层会自动向上弹出。
	var volume := VolumeControl.new()
	root.add_child(volume)
	volume.place_bottom_right(vsize, 10.0, 22.0)

	# 左下角"喊话"按钮(仅联机对战中显示)
	_build_chat_button(root, vsize)

# 屏幕边缘警告层：容器内四条浅红半透明边条；回合剩余时间不足时整体呼吸闪烁
func _build_edge_warning(root: Control, vsize: Vector2) -> void:
	_warn_holder = Control.new()
	_warn_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_warn_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_holder.visible = false
	root.add_child(_warn_holder)
	var edge := 24.0   # 边缘条厚度
	var bars := [
		[Vector2(0, 0), Vector2(vsize.x, edge)],               # 上
		[Vector2(0, vsize.y - edge), Vector2(vsize.x, edge)],  # 下
		[Vector2(0, 0), Vector2(edge, vsize.y)],               # 左
		[Vector2(vsize.x - edge, 0), Vector2(edge, vsize.y)],  # 右
	]
	for b in bars:
		var rect := ColorRect.new()
		rect.color = Color(1.0, 0.3, 0.28, 0.5)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.position = b[0]
		rect.size = b[1]
		_warn_holder.add_child(rect)

func _make_panel(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	return sb

# ================= 联机快捷喊话 =================
# 左下角按钮:点开预置言论面板(嘲讽/友好各几条),点选后发给对端;
# 收到对端喊话时在顶部状态栏(回合栏)下方弹气泡条,短暂停留后自动淡出。
const _CHAT_TAUNTS := [
	"就这？",
	"投降吧，没机会了",
	"这步走得不太行哦",
	"嘿嘿，别跑呀",
	"胜负已定！",
]
const _CHAT_FRIENDLY := [
	"打得不错！",
	"好险好险，精彩",
	"交个朋友，切磋愉快",
	"运气不错哈哈",
	"GG 打得漂亮",
]

func _build_chat_button(root: Control, vsize: Vector2) -> void:
	if not GameState.is_online:
		return
	var btn := Button.new()
	btn.text = "喊话"
	btn.custom_minimum_size = Vector2(76, 44)
	btn.add_theme_font_size_override("font_size", 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.18, 0.26, 0.92)
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.border_color = Color(0.6, 0.7, 1.0, 0.5)
	sb.set_border_width_all(1)
	btn.add_theme_stylebox_override("normal", sb)
	btn.pressed.connect(_toggle_chat_panel)
	btn.position = Vector2(10, vsize.y - 56 - 10)
	root.add_child(btn)
	_chat_btn = btn

func _toggle_chat_panel() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.queue_free()
		_chat_panel = null
		return
	var vsize := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_panel(Color(0.1, 0.1, 0.16, 0.96)))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)
	var add_group := func(title: String, color: Color, items: Array):
		var lbl := Label.new()
		lbl.text = title
		lbl.add_theme_font_size_override("font_size", 13)
		lbl.add_theme_color_override("font_color", color)
		v.add_child(lbl)
		for txt in items:
			var b := Button.new()
			b.text = txt
			b.custom_minimum_size = Vector2(200, 34)
			b.add_theme_font_size_override("font_size", 15)
			b.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
			var bs := StyleBoxFlat.new()
			bs.bg_color = Color(0.2, 0.22, 0.32, 0.95)
			bs.corner_radius_top_left = 8
			bs.corner_radius_top_right = 8
			bs.corner_radius_bottom_left = 8
			bs.corner_radius_bottom_right = 8
			b.add_theme_stylebox_override("normal", bs)
			b.pressed.connect(func():
				_send_chat(String(b.text)))
			v.add_child(b)
	add_group.call("嘲讽", Color(1.0, 0.55, 0.5), _CHAT_TAUNTS)
	add_group.call("友好", Color(0.5, 0.9, 0.6), _CHAT_FRIENDLY)
	var pw := 220.0
	panel.size = Vector2(pw, 0)
	add_child(panel)
	# 面板出现在左下角按钮上方
	await get_tree().process_frame
	var ph := panel.get_combined_minimum_size().y
	panel.position = Vector2(10, vsize.y - 56 - 10 - ph - 6)
	_chat_panel = panel

func _send_chat(txt: String) -> void:
	_close_chat_panel()
	if battle != null and is_instance_valid(battle):
		battle.send_quick_chat(txt)
		_show_chat_bubble(txt, true)   # 自己发的喊话本端也立刻回显（我方侧），不必等对端

func _close_chat_panel() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.queue_free()
	_chat_panel = null

# 收到对端喊话 -> 对方气泡（顶部回合栏下方、靠敌方侧）
func _show_peer_chat(txt: String) -> void:
	_show_chat_bubble(txt, false)

# 喊话气泡：own=true=我方发出(顶部回合栏下方靠左、我方计数一侧)；own=false=对端喊话(靠右、敌方一侧)。
# 两端各按自己视角落位：本端看自己发的在"我方"侧、对端发的在"敌方"侧，一眼分清谁在说话。
func _show_chat_bubble(txt: String, own: bool) -> void:
	if txt == "":
		return
	if _chat_bubble_tween != null and _chat_bubble_tween.is_valid():
		_chat_bubble_tween.kill()
	if _chat_bubble != null and is_instance_valid(_chat_bubble):
		_chat_bubble.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var bubble := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.16, 0.24, 0.94) if own else Color(0.24, 0.1, 0.12, 0.94)
	sb.corner_radius_top_left = 12
	sb.corner_radius_top_right = 12
	sb.corner_radius_bottom_left = 12
	sb.corner_radius_bottom_right = 12
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	sb.border_color = Color(0.5, 0.85, 1.0, 0.9) if own else Color(1.0, 0.4, 0.35, 0.9)
	sb.set_border_width_all(2)
	bubble.add_theme_stylebox_override("panel", sb)
	bubble.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Label.new()
	label.text = txt
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0) if own else Color(1.0, 0.78, 0.72))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.custom_minimum_size = Vector2(0, 40)
	bubble.add_child(label)
	add_child(bubble)
	_chat_bubble = bubble
	await get_tree().process_frame
	var bs := bubble.get_combined_minimum_size()
	bubble.size = bs
	# 顶部回合栏(54)下方弹气泡；我方发言贴左 12px（我方计数侧），对端发言贴右 12px，
	# 左右对称摆放（我方气泡位置不动），一眼分清谁在说话。
	var bx := 12.0
	if not own:
		bx = vsize.x - bs.x - 12.0
	bubble.position = Vector2(maxf(6.0, bx), 62.0)
	bubble.modulate.a = 0.0
	var t := create_tween()
	_chat_bubble_tween = t
	t.tween_property(bubble, "modulate:a", 1.0, 0.18)
	t.tween_interval(2.6)
	t.tween_property(bubble, "modulate:a", 0.0, 0.4)
	t.tween_callback(func():
		if is_instance_valid(bubble):
			bubble.queue_free()
		if _chat_bubble == bubble:
			_chat_bubble = null)

func _set_round_text(round_num: int, _player_side: bool) -> void:
	# 联机视角：本端操作的是"我方"，另一方是"敌方"。用 battle._my_side() 判断本端是否当前行动方。
	var my_turn := true
	if battle != null:
		my_turn = GameState.active_side == battle._my_side()
	# 非回合阶段（开局部署/竞技场选人/替补中）不声称"你的回合/敌方回合"：
	# 否则对方先部署/先手时顶部仍错误显示"你的回合"。
	var phase_txt := ""
	if battle != null and is_instance_valid(battle):
		if battle.state == Battle.State.ARENA_DRAFT:
			phase_txt = "竞技场选人"
		elif battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY:
			phase_txt = "部署选人"
		elif battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB:
			phase_txt = "替补"
	var side := phase_txt if phase_txt != "" else ("你的回合" if my_turn else "敌方回合")
	_round_label.text = "第 %d 回合 · %s" % [round_num, side]
	var normal_color := Color(0.5, 0.85, 1.0) if my_turn else Color(1.0, 0.5, 0.5)
	_round_label.add_theme_color_override("font_color", normal_color)
	# 扣血阶段视觉提醒：进入超回合扣血（当前测试：第 1 回合起）后，回合标签"燃烧"+火焰图标常驻脉动。
	var burning := GameState.should_apply_round_damage() and GameState.match_running and not GameState.match_over
	if _flame_icon != null:
		_flame_icon.visible = burning
	if burning:
		_start_round_fire()
	else:
		_stop_round_fire(normal_color)

# ---- 回合标签"燃烧"效果（第 11 回合起）----

# 让"第 x 回合 · 你的回合"文字按火焰色循环跳动 + 暗火色描边
func _start_round_fire() -> void:
	if _round_fire_tween != null and _round_fire_tween.is_valid():
		return   # 已在燃烧，不重复开
	_round_label.add_theme_constant_override("outline_size", 8)
	_round_label.add_theme_color_override("font_outline_color", Color(0.5, 0.1, 0.0))
	var cols := [
		Color(1.0, 0.98, 0.55),   # 亮黄（焰芯）
		Color(1.0, 0.62, 0.12),   # 橙（焰中）
		Color(1.0, 0.32, 0.05),   # 赤红（焰底）
	]
	var t := create_tween().set_loops()
	_round_fire_tween = t
	for i in cols.size():
		t.tween_method(_apply_round_fire_color, cols[i], cols[(i + 1) % cols.size()], 0.22)

func _apply_round_fire_color(c: Color) -> void:
	if _round_label != null and is_instance_valid(_round_label):
		_round_label.add_theme_color_override("font_color", c)

func _stop_round_fire(restore: Color) -> void:
	if _round_fire_tween != null:
		if _round_fire_tween.is_valid():
			_round_fire_tween.kill()
		_round_fire_tween = null
	_round_label.add_theme_constant_override("outline_size", 0)
	_round_label.add_theme_color_override("font_color", restore)

func _refresh_round() -> void:
	_set_round_text(GameState.round_number, GameState.active_side == GameState.SIDE_PLAYER)

# GameState 回合信号回调（对象方法，便于释放时自动断开）
func _on_round_changed(_r: int) -> void:
	_refresh_round()
	# 先手提示常驻到"对局正式开始"：进入战斗后第一个回合信号到达时收起
	if GameState.match_running and not GameState.match_over:
		_close_first_notice()

# 阵亡计数图标（骷髅）= 已阵亡，空心 = 尚未阵亡
func _refresh_deaths() -> void:
	if battle == null:
		return
	var total := battle.LOSS_DEATH_COUNT
	var pd := battle.player_dead
	var ed := battle.enemy_dead
	if pd == _last_pd and ed == _last_ed:
		return
	_last_pd = pd
	_last_ed = ed
	var ps := ""
	var es := ""
	for i in total:
		ps += "☠" if i < pd else "○"
		es += "☠" if i < ed else "○"
	# 联机视角：本端操作方为"我方"。用 battle._my_dead/_opp_dead 取对应图标串。
	var my_icons := ps
	var op_icons := es
	if battle != null and GameState.is_online and not GameState.is_host:
		my_icons = es   # 客户端：我方=敌方(红)阵亡
		op_icons = ps
	if _player_deaths:
		_player_deaths.text = "我方 " + my_icons
	if _enemy_deaths:
		_enemy_deaths.text = op_icons + " 敌方"

func _process(_dt: float) -> void:
	_refresh_deaths()
	_refresh_controls()
	# 检测战斗阶段切换（替补落位完成/部署完成/回输入态等）→ 补刷新顶部"第X回合·阶段"标签。
	# 阶段是本地状态机、无专门信号：仅在真正变化时刷新一次，避免每帧重写。
	if battle != null and is_instance_valid(battle):
		var st: int = battle.state
		if st != _last_phase_state:
			_last_phase_state = st
			_refresh_round()
	_update_turn_timer()
	_update_arena_pick_timer()
	_update_deploy_pick_timer()
	_update_score_tooltip_pos()
	_update_arena_touch_hold()   # 竞技场触屏：按住不动超时 -> 转为查看模式（长按）

# 部署面板上方大字倒计时：本端真人选人轮（battle.deploy_budget_active）显示共享预算剩余秒
func _update_deploy_pick_timer() -> void:
	if _deploy_timer_label == null or not is_instance_valid(_deploy_timer_label):
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.deploy_budget_active:
		var secs := int(ceil(battle.deploy_budget_left))
		_deploy_timer_label.visible = true
		_deploy_timer_label.text = str(max(secs, 0))
		_deploy_timer_label.add_theme_color_override("font_color",
			Color(1.0, 0.3, 0.25) if secs <= 5 else Color(1.0, 0.9, 0.4))
	else:
		_deploy_timer_label.visible = false

# 选人面板上方的大字倒计时：仅当本端正在 2 选 1（battle.arena_pick_time_left >= 0）
func _update_arena_pick_timer() -> void:
	if _arena_timer_label == null or not is_instance_valid(_arena_timer_label):
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.state != Battle.State.ARENA_DRAFT or battle.arena_pick_time_left < 0.0:
		_arena_timer_label.text = ""
		return
	var secs := int(ceil(battle.arena_pick_time_left))
	_arena_timer_label.text = str(secs)
	# 剩 ≤3 秒变红警示
	_arena_timer_label.add_theme_color_override("font_color",
		Color(1.0, 0.3, 0.25) if secs <= 3 else Color(1.0, 0.9, 0.4))

# 顶部回合倒计时：仅对局中"本端可操作回合"显示（部署/等待/敌方回合隐藏）。
# 剩余 ≤15 秒时屏幕边缘浅红闪烁提醒。
func _update_turn_timer() -> void:
	if _turn_timer_label == null:
		return
	var show_timer := false
	var low_time := false
	var secs := 0
	if battle != null and is_instance_valid(battle):
		var match_live := GameState.match_running and not GameState.match_over
		if match_live and GameState.active_side == battle._my_side() and battle.turn_time_left > 0.0:
			# 本端行动（含行动动画期间，不做 state==PLAYER_INPUT 判定，避免每次演出闪烁）：
			# 显示本地倒计时
			show_timer = true
			secs = int(ceil(battle.turn_time_left))
			low_time = secs <= 15   # 仅本端行动倒计时触发边缘警告
		elif GameState.is_online and match_live and GameState.active_side != battle._my_side():
			# 联机等待对端行动：显示对端剩余时间。
			# 值由 Battle 维护：切回合瞬间置满额、本地每帧递减、对端广播校准 -> 不会消失。
			show_timer = true
			secs = int(ceil(battle.peer_turn_time_left))
	if show_timer:
		_turn_timer_label.visible = true
		_turn_timer_label.text = "⏱ %d 秒" % secs
		_turn_timer_label.add_theme_color_override("font_color",
			Color(1.0, 0.35, 0.3) if secs <= 10 else Color(1.0, 0.9, 0.6))
	else:
		_turn_timer_label.visible = false
	_set_edge_warning(low_time)

# 屏幕边缘浅红闪烁：剩余时间 ≤15 秒开启（呼吸效果），否则隐藏
func _set_edge_warning(on: bool) -> void:
	if _warn_holder == null:
		return
	if on and not _warn_holder.visible:
		_warn_holder.visible = true
		if _warn_tween != null and _warn_tween.is_valid():
			_warn_tween.kill()
		_warn_tween = create_tween().set_loops()
		_warn_tween.tween_property(_warn_holder, "modulate:a", 0.65, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_warn_tween.tween_property(_warn_holder, "modulate:a", 0.2, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	elif not on and _warn_holder.visible:
		_warn_holder.visible = false
		if _warn_tween != null and _warn_tween.is_valid():
			_warn_tween.kill()
			_warn_tween = null
		_warn_holder.modulate.a = 1.0   # 复位，避免下次显示时残留透明度

# 按钮可用性/可见性刷新：
# 1) 结束回合：仅当本端操作方 == 当前行动方且处于我方输入状态时可点（非我方回合禁用）；
# 2) 重开：联机（含联机竞技场）不需要，隐藏；
# 3) 返回：联机返回大厅，单机返回选人界面。
func _refresh_controls() -> void:
	var my_turn := false
	if battle != null:
		my_turn = battle.state == Battle.State.PLAYER_INPUT and GameState.active_side == battle._my_side()
	if _end_btn != null:
		_end_btn.disabled = not my_turn
	if _restart_btn != null:
		_restart_btn.visible = not GameState.is_online
	if _back_btn != null:
		_back_btn.visible = true
		_back_btn.text = "返回大厅" if GameState.is_online else "返回选人"

# 属性浮层实时跟随鼠标，并收敛到屏幕内（避免被底部/右侧挡住）
# 触屏长按查看时 _tooltip_pin_rect 非空：固定显示在目标卡上方，不跟随手指（避免被手指遮挡）。
# 竞技场倒计时在屏幕中央上方：查看左卡则浮层靠左、查看右卡则靠右，中央让位给倒计时。
func _update_score_tooltip_pos() -> void:
	if _score_tooltip_wrap == null or not _score_tooltip_wrap.visible:
		return
	var vs := get_viewport().get_visible_rect().size
	var tw := _score_tooltip_wrap.size.x
	var th := _score_tooltip_wrap.size.y
	var pos: Vector2
	if not _tooltip_pin_rect.size.is_zero_approx():
		# 纵向：优先显示在卡上方（避免手指遮挡）；上方不够则贴顶/卡下方兜底
		pos = Vector2.ZERO
		pos.y = _tooltip_pin_rect.position.y - th - 10.0
		if pos.y < 8.0:
			pos.y = 8.0
		# 横向：按查看卡所在半边贴边，中央让给倒计时
		var mid := vs.x / 2.0
		var pin_cx := _tooltip_pin_rect.position.x + _tooltip_pin_rect.size.x / 2.0
		if pin_cx < mid:
			# 查看左侧卡 -> 浮层靠左，右缘不越过中央
			pos.x = 8.0
			if pos.x + tw > mid - 6.0:
				pos.x = maxf(8.0, mid - 6.0 - tw)
		else:
			# 查看右侧卡 -> 浮层靠右，左缘不越过中央
			pos.x = vs.x - tw - 8.0
			if pos.x < mid + 6.0:
				pos.x = mid + 6.0
		pos.x = clampf(pos.x, 8.0, maxf(8.0, vs.x - tw - 8.0))
		pos.y = clampf(pos.y, 8.0, maxf(8.0, vs.y - th - 8.0))
		_score_tooltip_wrap.position = pos
		return
	var mp := get_viewport().get_mouse_position()
	# 默认在鼠标右上方；若右缘/上方越界则翻转/收敛
	pos = mp + Vector2(16, 18)
	if pos.x + tw > vs.x - 4:
		pos.x = mp.x - tw - 10   # 翻到鼠标左侧
	if pos.y + th > vs.y - 190:   # 底部留出按钮行，改为弹到鼠标上方
		pos.y = mp.y - th - 10
	pos.x = clampf(pos.x, 4, vs.x - tw - 4)
	pos.y = clampf(pos.y, 4, vs.y - th - 4)
	_score_tooltip_wrap.position = pos

func _on_end_turn() -> void:
	if battle and battle.state == Battle.State.PLAYER_INPUT:
		battle.submit_end_turn()

func _on_restart() -> void:
	if _result_overlay != null:
		# 关闭结算浮层（场景不卸载，需手动收起，否则遮住重开的选人/部署界面）
		_result_overlay.queue_free()
		_result_overlay = null
	# 重开前收起棋盘下方的全部临时面板：常驻"替补队伍/替补选人"与开局部署面板。
	# 否则在替补阶段（SUBSTITUTING/PLACE_SUB）点重开时，reset_match 只重置战斗数据，
	# 已打开的面板不会随 deploy_refresh 收起，上一局的英雄行会残留在屏底。
	_close_team_panel()
	_close_deploy_panel()
	if battle != null and is_instance_valid(battle):
		if GameState.is_online:
			battle.request_rematch_online()   # 联机：请求再来一局（不退出连接/大厅）
		else:
			battle.reset_match()   # 重置本局（不卸载场景，避免 reload 打断异步导致 get_tree() null 崩溃）
	elif GameState.is_online:
		# 异常兜底（Battle 已失效）：退回联机大厅
		NetBus.stop()
		GameState.reset_online()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
	else:
		get_tree().reload_current_scene()

func show_result(win: bool) -> void:
	if _result_overlay != null:
		_result_overlay.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	_result_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 20)
	box.position = Vector2(vsize.x / 2 - 160, vsize.y / 2 - 150)
	box.size = Vector2(320, 300)
	overlay.add_child(box)

	var title := Label.new()
	title.text = "胜　利！" if win else "败　北……"
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.4) if win else Color(1, 0.45, 0.4))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var sub := Label.new()
	sub.text = "敌方英雄阵亡达 3 名。" if win else "我方英雄阵亡达 3 名。"
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	box.add_child(_vspacer(12))

	var again := Button.new()
	again.text = "再来一局" if GameState.is_online else "再战一局"
	again.custom_minimum_size = Vector2(260, 52)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(_on_restart)
	box.add_child(again)
	# 单机/联机都显示：联机由主机权威广播重启（不退出大厅连接）

	var to_menu := Button.new()
	to_menu.text = "返回选卡" if not GameState.is_online else "返回大厅"
	to_menu.custom_minimum_size = Vector2(260, 48)
	to_menu.add_theme_font_size_override("font_size", 18)
	to_menu.pressed.connect(_on_back_to_menu)
	box.add_child(to_menu)

func _vspacer(h: float) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s

func _on_back_to_menu() -> void:
	if GameState.is_online:
		# 联机（含联机竞技场）：返回联机大厅（断开连接、清联机状态，可重新开房/加入）
		GameState.reset_online()
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
		return
	GameState.arena_mode = false   # 返回选人界面：退出竞技场模式（再来一局时不再走竞技场）
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

# 扣血提醒火焰图标：纯代码自绘（不依赖 emoji 字体），在 _process 里脉动跳动。
class FlameIcon extends Control:
	var _t := 0.0
	var size_px := 30.0

	func _process(dt: float) -> void:
		_t += dt
		queue_redraw()

	func _draw() -> void:
		var c := size / 2.0
		var w := size_px
		var sway := sin(_t * 7.0) * 1.5   # 左右摆动
		var flick := 0.85 + 0.15 * sin(_t * 11.0)   # 亮度抖动
		# 外焰（红橙）— 底部宽圆 + 顶部尖角
		var outer := PackedVector2Array([
			Vector2(c.x - w * 0.34 + sway, c.y + w * 0.42),
			Vector2(c.x - w * 0.18 + sway, c.y + w * 0.08),
			Vector2(c.x, c.y - w * 0.52),
			Vector2(c.x + w * 0.18 + sway, c.y + w * 0.08),
			Vector2(c.x + w * 0.34 + sway, c.y + w * 0.42),
		])
		draw_colored_polygon(outer, Color(1.0, 0.3, 0.1, 0.95 * flick))
		# 内焰（金黄）
		var inner := PackedVector2Array([
			Vector2(c.x - w * 0.14 + sway, c.y + w * 0.3),
			Vector2(c.x - w * 0.05 + sway, c.y - w * 0.1),
			Vector2(c.x, c.y - w * 0.28),
			Vector2(c.x + w * 0.06 + sway, c.y - w * 0.05),
			Vector2(c.x + w * 0.14 + sway, c.y + w * 0.3),
		])
		draw_colored_polygon(inner, Color(1.0, 0.85, 0.3, 0.95 * flick))
		# 焰心（白亮）
		var core := PackedVector2Array([
			Vector2(c.x - w * 0.04 + sway, c.y + w * 0.18),
			Vector2(c.x, c.y - w * 0.05),
			Vector2(c.x + w * 0.05 + sway, c.y + w * 0.18),
		])
		draw_colored_polygon(core, Color(1.0, 1.0, 0.85, 0.9))
