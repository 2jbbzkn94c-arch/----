class_name HUD
extends CanvasLayer
## 战斗界面浮层：显示回合/阵营、消息日志、操作提示，并放置结束回合/重开按钮。

var battle: Battle

var _round_label: Label
## 【2026-09-27】顶部中间那组的"上一次排版输入"（回合文字 + 倒计时文字 + 火焰是否亮 + 视口宽）——
##   用它挡掉重复的 `_fit_top_center()`（`_update_turn_timer()` 调得很勤）。
var _top_fit_key := ""
var _last_phase_state := -1   # 上次刷新时的 Battle.state（_process 检测阶段切换，补刷新顶部标签）
var _turn_banner: Label = null       # 回合切换中央大字横幅（短暂显示后自动消失）
var _turn_banner_tween: Tween = null
var _flame_icon: Control = null   # 扣血提醒火焰（第11回合起常驻脉动）
var _round_fire_tween: Tween = null   # 回合标签的"燃烧"颜色脉动 tween（第11回合起）
var _turn_timer_label: Label   # 本端回合剩余时间（对局中我方回合显示）
var _result_overlay: Control = null
var _netdown_overlay: CanvasLayer = null   # 联机对局断线提示层
var _team_panel: PanelContainer = null    # 下方常驻队伍展示（整支卡组，含替补）——替补阶段复用为"选人面板"
# 下方队伍卡行的半径上限（【2026-09-28】按可用宽度反算后再封顶）：
#   一行 n 张平顶六边形的总宽 = `2r + (n−1)·1.5r` ⇒ **8 张一行的物理上限 = 视口宽 / 12.5 ≈ 57**
#   （720 视口）。所以"8 个英雄占满宽度"时每张卡最大就这么大；想明显更大只能改两行（4+4）或让卡重叠。
const _TEAM_ROW_MAX_R := 56.0
var _arena_panel: PanelContainer = null   # 竞技场选人面板（2选1）
var _deck_pick_overlay: Control = null     # 普通模式"选择卡组"面板（进战斗后弹：卡组1/2/3 切换 + 随机英雄）
# 【2026-09-23】常驻战斗 UI 的根（`_build()` 里那个 Control）：`结束回合/重开/返回选人/暂停` 都在它下面。
# 临时遮罩挂到 HUD（CanvasLayer）会**盖住这些按钮** ⇒ 弹"选择卡组"时点不了重开/退出；
# 插进 `_ui_root` 的第 0 个子节点就两全：棋盘照旧被拦（HUD 层在棋盘之上），按钮仍在遮罩之上。
var _ui_root: Control = null
var _deck_pick_decks: Array = []           # 面板持有的 3 个已存卡组（下标0=卡组1）
var _deck_pick_slot := 1                   # 当前查看的卡组槽（1..3）
var _deck_pick_tabs: Dictionary = {}       # slot -> Button（卡组1/2/3 切换钮）
var _deck_pick_preview: Control = null     # 当前卡组的队伍预览宿主
var _deck_pick_info: Label = null          # 当前卡组信息行（人数/不足提示）
var _deck_pick_start_btn: Button = null     # 用当前卡组出战
# 【2026-09-21 用户定】选卡组限时大字（读 `battle.deck_pick_time_left`，15 秒，超时随机选一个）
var _deck_pick_timer_label: Label = null
var _deck_pick_panel: PanelContainer = null # 面板本体（切换卡组后重算尺寸定位）
# 【2026-09-23 修·用户报"点击卡组切换后弹窗会左右移动"】面板尺寸**只在首次量一次**：
#   量的是"三个卡组里人最多的那支"（卡行最宽）+ 最宽形态的限时大字（两位数秒）。
#   原来每次点 卡组1/2/3 都按**当前**内容重算宽度并重新居中 ⇒ 卡行人头数 / 秒数位数一变，
#   弹窗就整体左右跳（而且 `reset_size()` 清不掉 `custom_minimum_size` ⇒ 宽度只增不减）。
var _deck_pick_panel_w := 0.0
var _deck_pick_panel_h := 0.0
var _arena_timer_label: Label = null      # 选人倒计时（选卡面板上方的大字）
# 【2026-09-23 改·用户要求"死亡时卡面破碎升天 → 引导到顶部阵亡标志 → 标志出现并摇晃"+ "空圈和骷髅一样大"】
#   原来每侧是一个 Label 拼字符串（`"我方 ☠☠☠"`）⇒ ① `○` 与 `☠` 字形不一样大、整行会漂；
#   ② 没法定位到"具体哪一个标记"去做飞行终点与单独摇晃。
#   现在拆成：每侧 = 一个名字 Label + `LOSS_DEATH_COUNT` 个 `DeathMark` 槽（固定尺寸、自绘圆环/骷髅）。
var _my_death_name: Label = null
var _op_death_name: Label = null
var _my_marks: Array = []      # 本端视角的"我方"那排（左）
var _op_marks: Array = []      # 本端视角的"对方"那排（右）
var _death_fx: DeathFx = null  # 阵亡演出层（全屏，只画特效；比状态栏晚加入 ⇒ 画在状态栏之上）
# 延迟揭示：真实阵亡数（战斗逻辑）先涨，**标志等卡片落地才出现** ⇒ `_reveal_pending` = 已死亡但还没点亮的个数。
# 槽位 `filled` 的个数记在 `_mark_filled` 里（= 界面上看到的），两者相加 = 真实阵亡数。
var _reveal_pending := { "my": 0, "op": 0 }
var _mark_filled := { "my": 0, "op": 0 }
var _pause_btn: Button = null        # 暂停键（仅单机显示，放右上角）
var _pause_overlay: Control = null   # 暂停遮罩（暂停时显示"已暂停/继续游戏"）
var _ladder_confirm: Control = null  # 【天梯】"确定放弃本次天梯？"的再确认层（用户要求）
# 【2026-09-25 用户要求·天梯主动放弃】放弃确认后**也要弹结算面板**（提示"才X连胜，跑什么？去简单难度偷偷进步啊？"）
#   ⇒ 这个一次性标记让 `show_result()` 知道"这次是放弃、不是打输"（用它选文案 + 保持整棵树暂停）。
var _ladder_gave_up := false
# 【2026-09-23 深夜·用户贴的 `HUD.gd:54 UNUSED_PRIVATE_CLASS_VARIABLE`】这两行是老"整行文字"版阵亡栏
#   留下的计数器（`_last_pd`/`_last_ed`）—— 2026-09-23 改成**逐槽 DeathMark** 后，界面状态改由
#   `_reveal_pending` / `_mark_filled` 记录 ⇒ 这两个再没人读写，已删除（纯删死变量，行为零变化）。
var _last_my_text := ""   # 上次刷新的"我方"侧文字（联机=姓名；用于姓名变化时补刷新）
var _last_op_text := ""   # 上次刷新的"敌方"侧文字（联机=姓名）
var _end_btn: Button          # 结束回合（仅我方回合可点）
# 【2026-09-27·用户要求】结束回合按钮换成图片（图缺失时自动退回原来的金色文字按钮）
const END_TURN_TEX := "res://assets/界面/结束回合.png"
const END_BTN_IMG_H := 112.0   # 图片按钮的高度（宽按图的比例 ⇒ 112 × 237/209 ≈ 127）
# 【2026-09-27】底部常驻行现在只有「结束回合」；`_restart_btn` 已随"重开/返回选人整合进暂停面板"移除。
# 【2026-09-28·用户要求】联机那枚「返回大厅」也删掉 ⇒ 底部行两种模式都只剩「结束回合」；
#   联机退出改走**右上角「认输」**：先喊一句完整的话给对端，再走认输结算（退出大厅走结算面板的按钮）。
var _surrender_btn: Button = null   # 【2026-09-28】联机：右上角「认输」（单机恒为 null）
var _warn_holder: Control = null   # 回合剩余时间不足警告：屏幕边缘浅红闪烁
var _warn_tween: Tween = null      # 边缘警告呼吸 tween
var _unit_card_overlay: Control = null   # 右键英雄信息卡（成员持有，避免 lambda 捕获被释放节点）
# 【2026-09-27·用户要求】开局"先手"提示整块删除（先文字、后图片都删了）：不再有任何提示 UI。
# 联机快捷喊话:左下角按钮 + 选言面板 + 顶部气泡
var _chat_btn: Button = null
var _chat_panel: PanelContainer = null
var _chat_overlay: Control = null   # 选言面板的全屏透明层：点面板以外任意处收起
var _chat_bubble: PanelContainer = null
var _chat_bubble_tween: Tween = null

func _ready() -> void:
	layer = 50
	_build()
	NetBus.disconnected.connect(_on_battle_disconnected)   # 对局中断线弹提示（不再直接跳场景）

# 联机对局断线：弹出"已断线，本局无法继续"提示，用户点按钮后回大厅
func _on_battle_disconnected() -> void:
	if not GameState.is_online or _netdown_overlay != null:
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.state == Battle.State.ENDED:
		return   # 已结算：结算按钮处理
	var ovly := CanvasLayer.new()
	ovly.layer = 95
	add_child(ovly)
	_netdown_overlay = ovly
	var vsize := get_viewport().get_visible_rect().size
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ovly.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	ovly.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	box.custom_minimum_size = Vector2(500, 0)
	panel.add_child(box)
	var title := Label.new()
	title.text = "连接已断开"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var line := HSeparator.new()
	box.add_child(line)
	var note := Label.new()
	note.text = "对方已离开，本局无法继续。"
	note.add_theme_font_size_override("font_size", 20)
	note.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(460, 0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(note)
	var hint := Label.new()
	hint.text = "点「返回大厅」回到联机大厅，可重新开房或重新连接。"
	hint.add_theme_font_size_override("font_size", 17)
	hint.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(460, 0)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(hint)
	var bt := Button.new()
	bt.text = "返回大厅"
	bt.custom_minimum_size = Vector2(0, 60)
	bt.add_theme_font_size_override("font_size", 22)
	bt.pressed.connect(_on_netdown_back)
	box.add_child(bt)
	panel.reset_size()
	panel.position = Vector2((vsize.x - panel.size.x) / 2.0, (vsize.y - panel.size.y) / 2.0)

func _on_netdown_back() -> void:
	if _netdown_overlay != null:
		_netdown_overlay.queue_free()
		_netdown_overlay = null
	GameState.reset_online()
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")

func bind(b: Battle) -> void:
	battle = b
	battle.match_result.connect(show_result)
	battle.sub_select_requested.connect(_refresh_team_panel)   # 替补阶段：同一队伍面板切换为可点选
	battle.sub_placed.connect(_on_sub_placed)
	battle.arena_draft_requested.connect(_show_arena_pair)
	battle.arena_draft_done.connect(_close_arena_panel)
	battle.deck_pick_requested.connect(_show_deck_pick_panel)
	battle.deck_pick_done.connect(_close_deck_pick_panel)
	# 【2026-09-23 新增】阵亡演出：死亡瞬间（比 match_result / 替补早 0.3s）播"破碎升天 → 飞向阵亡标志"
	battle.unit_dying.connect(_on_unit_dying)
	battle.team_updated.connect(_refresh_team_panel)
	battle.deploy_refresh.connect(_show_deploy_panel)
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
func show_item_info(type: String, owner_faction: int = -1) -> void:
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
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png），不再单独覆盖样式
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
	# 【2026-09-21 用户定稿·圣诞老人】道具提示要**说明归属**：带归属的道具只有放置方能拾取，
	#   对方踩上去会直接消失（板面上也按归属描边：我方绿 / 敌方红）。
	var own_txt := "（中立道具：双方都能拾取）"
	if owner_faction == DataRegistry.Faction.PLAYER:
		own_txt = "（我方道具：只有我方能拾取，敌方踩到会消失）"
	elif owner_faction == DataRegistry.Faction.ENEMY:
		own_txt = "（敌方道具：只有敌方才能拾取，我方踩到会消失）"
	desc.text = battle.item_desc(type) + "\n" + own_txt
	# 标题也带上归属，一眼看清是谁的（配色与板面右下角圆点一致：我方蓝 / 敌方红）
	if owner_faction == DataRegistry.Faction.PLAYER:
		title.text = "增益道具 · 我方"
		title.add_theme_color_override("font_color", Color(0.45, 0.7, 1.0))
	elif owner_faction == DataRegistry.Faction.ENEMY:
		title.text = "增益道具 · 敌方"
		title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
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
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
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
	# 数值带增益时用黄色（与棋子上那两个数字同一口径，见 Unit.atk_is_buffed / Unit.hp_is_buffed）：
	# 用 RichTextLabel + BBCode 才能只给"攻击 4"/"HP 27/24"上色，其余文字保持原色。
	var stats := RichTextLabel.new()
	stats.bbcode_enabled = true
	stats.fit_content = true          # 高度随内容（面板无容器重排，避免留白）
	stats.scroll_active = false
	stats.custom_minimum_size = Vector2(270, 0)   # 限制换行宽度，避免撑满全屏
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats.add_theme_font_size_override("normal_font_size", 17)
	stats.add_theme_color_override("default_color", Color(0.9, 0.93, 1.0))
	# 与全局 Label 一致的黑描边（主题对 Label 设了 outline，RichTextLabel 要自己补）
	stats.add_theme_constant_override("outline_size", 3)
	stats.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	# 大骑士移动=直线冲锋任意距离、坠炮手射程=全场：按 ∞ 展示（由英雄脚本声明是否生效，
	# 被沉默失效时自动退回普通数值），不显示误导性的数值
	var move_txt := "%d" % u.effective_move()
	if battle != null and is_instance_valid(battle) and battle._hero(u).shows_infinite_move():
		move_txt = "∞"
	# 卡面射程取"有效射程"：被[沉默]/[眩晕]时被动失效的英雄（血锁的射程+2）要显示退化值。
	# 与 Battle 取用 suppressed_attack_range() 的口径完全一致（Battle.gd:2435-2443 / 2463-2471：
	# -1 = 用原始 attack_range，>=0 = 用该返回值），避免卡面与实际不符（用户实机反馈）。
	var shown_range: int = u.attack_range
	if battle != null and is_instance_valid(battle):
		var sup := battle._hero(u).suppressed_attack_range()
		if sup >= 0:
			shown_range = sup
	var range_txt: String = "%d" % shown_range
	if battle != null and is_instance_valid(battle) and battle._hero(u).shows_infinite_range():
		range_txt = "∞"   # 坠炮手"全场射程"特例仍然优先（不受上面退化值影响）
	# 带增益的数值用黄色（棋子上的同款口径）：HP 溢出上限 / 攻击力带 buff
	var hp_txt := "HP %d/%d" % [u.hp, u.max_hp]
	if u.hp_is_buffed():
		hp_txt = "[color=#ffe640]%s[/color]" % hp_txt
	var atk_txt := "攻击 %d" % u.effective_atk()
	if u.atk_is_buffed():
		atk_txt = "[color=#ffe640]%s[/color]" % atk_txt
	stats.text = "[center]%s   %s   移动 %s   射程 %s[/center]" % [hp_txt, atk_txt, move_txt, range_txt]
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
		# 显示区⑤：当前已挂状态的具体解释（名字只是状态行里的提示，这里补完整说明）
		var st_ex := _status_explain_lines(u)
		if st_ex.size() > 0:
			v.add_child(_make_zone_sep())
			var stl := Label.new()
			stl.text = "当前状态\n" + "\n".join(st_ex)
			stl.add_theme_font_size_override("font_size", 16)
			stl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.7))
			stl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			stl.custom_minimum_size = Vector2(270, 0)
			stl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			v.add_child(stl)
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
## `color` / `hold` 都有默认值（对局那条信号路径一个字不改）：回放会传阵营色与更长的停留，
## 让"这一回合轮到哪一方"更显眼（用户 2026-09-27 要求）。
func _show_turn_banner(text: String, color: Variant = null, hold: float = 0.9) -> void:
	if _turn_banner_tween != null and _turn_banner_tween.is_valid():
		_turn_banner_tween.kill()
	if _turn_banner != null and is_instance_valid(_turn_banner):
		_turn_banner.queue_free()
	var vs := get_viewport().get_visible_rect().size
	var label := Label.new()
	label.name = "TurnBanner"
	label.text = text
	label.add_theme_font_size_override("font_size", 54)
	label.add_theme_color_override("font_color", (color as Color) if color != null else Color(1.0, 0.9, 0.45))
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
	t.tween_interval(hold)
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
		# 【2026-09-27 修·用户报「录像里右键英雄会弹出两次属性框」】`accept_event()` 只作用于 Control 树，
		#   管不住 `Battle._unhandled_input` —— 右键关掉浮层后那个事件还会漏到 Battle，被当成"右键查看"
		#   又开一张 ⇒ 看着就是弹两次。这里在**视口层**标成已处理，彻底止住。
		get_viewport().set_input_as_handled()
		return true
	return false

# 等 PanelContainer 完成布局后按内容尺寸定位并收敛到屏内（overlay/panel 由成员引用，安全判空）
func _position_unit_card(overlay: Control, panel: PanelContainer, vsize: Vector2) -> void:
	var wait := get_tree().create_timer(0.05, false)
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

# 状态行文本：名称与顺序都来自 StatusDB（以前这里又抄了一份"键→中文名"的表）
func _status_text(u: Unit) -> String:
	var s := ""
	for key in StatusDB.keys():
		if u.has_status(key):
			s += StatusDB.label(key) + " "
	return s if s != "" else "无"

# 当前每个状态的解释(属性框用)：名称取自 StatusDB，说明取自 DataRegistry.STATUS_DESC
func _status_explain_lines(u: Unit) -> Array:
	var out: Array = []
	for key in StatusDB.keys():
		if not u.has_status(key):
			continue
		var label := StatusDB.label(key)
		var desc: String = DataRegistry.STATUS_DESC.get(label, "")
		out.append("%s：%s" % [label, desc] if desc != "" else label)
	return out

# 开局部署面板（分步：点选英雄 -> 点击出生格放置）
var _deploy_overlay: Control = null
var _deploy_timer_label: Label = null   # 部署轮倒计时（面板上方大字，与竞技场选人一致）
func _show_deploy_panel() -> void:
	if _in_replay():
		_close_deploy_panel()   # 【录像回放】回放里永不显示"开局选人/部署"面板（含那行大字倒计时）
		return
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
	# 【2026-09-27·用户要求】原来这里有一行标题「开局选人 · 点选英雄部署 · 我方 x/3 对方 x/3」⇒ **整行删掉**，
	#   面板直接就是卡池那一行（`side_txt` / 标题 Label / 计数都随之消失）。
	var placing := battle.state == Battle.State.PLACE_DEPLOY
	# 当前轮是否轮到本端部署选人
	var my_pick := _deploy_my_pick()
	# 卡池：始终为本端"我方"部署卡池；轮到本端才可点选
	var ids: Array = battle._my_deploy_pool()
	var sel := battle._pending_deploy
	if battle._my_faction() == DataRegistry.Faction.ENEMY:
		sel = battle._pending_enemy_deploy
	var pool := _make_hex_pool(ids, _on_deploy_hover, _on_deploy_click, not my_pick or placing, sel, true, 48.0)
	# 【2026-09-27·用户报「队伍有点压着棋盘 / 太下了挡住结束按钮」】卡池宿主高度要按**交错排布**算：
	#   单行时奇数列的卡往下错半行 ⇒ 最低那张卡底边 = `r + √3·r`（r=48 ⇒ 131px），
	#   而 `_make_hex_pool` 给的是 2×行距（166px，多留的空白会把整排卡往上顶）；
	#   我第一次收紧到 1.15×行距（96px）又**太短** ⇒ 奇数列的卡溢出面板盒、正好压到结束回合按钮上。
	#   ⇒ 按实际用量收：`r + √3·r` 再留 6px 余量（卡片绝对定位、宿主不裁剪 ⇒ 只影响面板盒）。
	pool.custom_minimum_size.y = 48.0 * (1.0 + sqrt(3.0)) + 6.0
	pool.size.y = pool.custom_minimum_size.y
	wrapbox.add_child(pool)
	var pw: float = pool.custom_minimum_size.x + 20.0
	var ph: float = pool.custom_minimum_size.y + 10.0
	panel.custom_minimum_size = Vector2(pw, ph)
	panel.size = Vector2(pw, ph)
	# 底边固定在按钮行上方 8px。面板本身**透明且不拦鼠标** ⇒ 即便盒底伸到按钮带里也看不见、点不到。
	panel.position = Vector2((vsize.x - pw) / 2.0, vsize.y - END_BTN_IMG_H - 18.0 - ph)
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
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）：不再覆盖样式
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

# ---- 普通模式：进入战斗后弹"选择卡组"面板 ----
# 样式与普通模式编辑页一致：卡组1/2/3 切换钮（点哪个显示哪个队伍）+ 右侧"随机英雄"。
# 只展示已保存的卡组（场内不可编辑英雄），卡牌可悬停查看属性；不足 5 名时点出战弹提示。
func _show_deck_pick_panel(decks: Array) -> void:
	_refresh_round()   # 顶部标签显示"选择卡组"
	_close_deck_pick_panel()
	_close_arena_panel()
	_close_deploy_panel()
	_close_team_panel()
	_deck_pick_decks = decks
	_deck_pick_slot = 1
	# 全屏遮罩拦截棋盘输入（面板打开期间不允许操作棋盘）
	# 【2026-09-23 修·用户报"弹这个框时没法重开或者退出"】遮罩插进 `_ui_root` 的**第 0 个子节点**
	#   （常驻 UI 的最底层）—— 原来 `add_child` 到 HUD 这个 CanvasLayer 上，会连
	#   `结束回合/重开/返回选人/暂停` 一起盖住（看得见、点不到）。插进 root 之后：
	#   棋盘仍被拦住（HUD 层在棋盘之上），而常驻按钮在遮罩之上 ⇒ 照旧可点。
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	if _ui_root != null and is_instance_valid(_ui_root):
		_ui_root.add_child(overlay)
		_ui_root.move_child(overlay, 0)
	else:
		add_child(overlay)
	_deck_pick_overlay = overlay
	# 【2026-09-23 用户要求】弹窗背后加一层暗色遮罩（"背景淡化"）：与结算浮层同一套做法
	#   （全屏 ColorRect，**alpha 越接近 1 越黑**；0.45 = 棋盘看得清、只是压一层灰）。
	#   原来这里是纯透明 ⇒ 棋盘照旧亮着，弹窗像是"浮"在场上、读卡组信息时很跳；
	#   2026-09-28 用户口径「背景透明度」⇒ 由 0.7 调淡到 **0.45**（想更透/更暗只改这一个数）。
	#   ⚠️ 只负责变暗、不接输入（`MOUSE_FILTER_IGNORE`）：点棋盘仍由 overlay 拦，按钮照旧可点。
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）；
	# ⚠️ 原来这块面板是半透明"透出棋盘"的，换成牌子后变成不透明（弹窗更聚焦）。
	overlay.add_child(panel)
	_deck_pick_panel = panel
	# 【2026-09-28·用户口径「背景透明度」= 要透出棋盘的是**这块牌子本身**】⇒ 把主题那块边框**复制一份**、
	#   只压低它的 `modulate_color.a`（**主题与其它弹窗一律不动**）：牌子变透，而牌子里的字/卡/按钮
	#   仍是全不透明（它们不是样式的一部分，只受节点自身影响）。
	#   想更透/更实只改 `PLATE_ALPHA`：0.45 很透 / 0.65 现在 / 1.0 = 原样不透明。
	#   ⚠️ 必须在 `add_child` **之后**取样式：主题查找要沿节点树往上找（进树了才拿得到项目主题）。
	const PLATE_ALPHA := 0.65
	var base_sb := panel.get_theme_stylebox("panel")
	if base_sb is StyleBoxTexture:
		var plate: StyleBoxTexture = (base_sb as StyleBoxTexture).duplicate()
		plate.modulate_color = Color(1, 1, 1, PLATE_ALPHA)
		panel.add_theme_stylebox_override("panel", plate)
	var wrapbox := VBoxContainer.new()
	wrapbox.add_theme_constant_override("separation", 10)
	panel.add_child(wrapbox)
	var title := Label.new()
	title.text = "选择卡组出战"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(title)
	# 【2026-09-21 用户定】限时大字：15 秒内不选 ⇒ 随机选一个可用卡组（Battle 侧 `_deck_pick_timeout()`）。
	# 样式与部署轮/竞技场那两处大字同一套（金 → ≤5 秒转红，见 `_update_deck_pick_timer`）。
	_deck_pick_timer_label = Label.new()
	_deck_pick_timer_label.add_theme_font_size_override("font_size", 32)
	_deck_pick_timer_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.4))
	_deck_pick_timer_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_deck_pick_timer_label.add_theme_constant_override("outline_size", 5)
	_deck_pick_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ⚠️ 先填"最宽形态"（两位数秒）再量面板：原来这里是空串 ⇒ 第一帧文字进来后内容变宽、
	#   面板向右长；下一次点卡组切换又按带文字的宽度重新居中 ⇒ 整体左移（"弹窗左右移动"的半个病灶）。
	_deck_pick_timer_label.text = "%d 秒（超时随机选一个卡组）" % int(Battle.DECK_PICK_TIME_LIMIT)
	wrapbox.add_child(_deck_pick_timer_label)
	# 卡组1/2/3 切换行（同编辑页 deck_bar 布局：tabs 占满整行，右侧放按钮）
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapbox.add_child(bar)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(tabs)
	for slot in [1, 2, 3]:
		var tab := Button.new()
		tab.text = "卡组 %d" % slot
		tab.toggle_mode = true
		tab.custom_minimum_size = Vector2(0, 34)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.pressed.connect(_on_deck_pick_tab.bind(slot))
		tabs.add_child(tab)
		_deck_pick_tabs[slot] = tab
	# 卡组1/2/3 右边 = 随机英雄
	var rand_btn := Button.new()
	rand_btn.text = "随机英雄"
	rand_btn.add_theme_font_size_override("font_size", 15)
	rand_btn.custom_minimum_size = Vector2(130, 34)
	rand_btn.pressed.connect(_on_deck_pick_random_pressed)
	bar.add_child(rand_btn)
	# 当前卡组信息行
	_deck_pick_info = Label.new()
	_deck_pick_info.add_theme_font_size_override("font_size", 14)
	_deck_pick_info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	_deck_pick_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wrapbox.add_child(_deck_pick_info)
	# 当前卡组的队伍预览（点卡组1/2/3 切换显示；悬停卡牌看属性）
	var host := Control.new()
	host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapbox.add_child(host)
	_deck_pick_preview = host
	# 出战按钮
	_deck_pick_start_btn = Button.new()
	_deck_pick_start_btn.add_theme_font_size_override("font_size", 18)
	_deck_pick_start_btn.custom_minimum_size = Vector2(0, 42)
	_deck_pick_start_btn.pressed.connect(_on_deck_pick_confirm)
	wrapbox.add_child(_deck_pick_start_btn)
	# 【2026-09-23 修】先按"人最多的那支卡组"量一次面板尺寸（尺寸只在这次定下来，见 `_layout_deck_pick_panel`）
	#   ⇒ 之后点 卡组1/2/3 只换内容、不再重算尺寸，弹窗不会左右移动。
	var widest := 1
	for i in _deck_pick_decks.size():
		if (_deck_pick_decks[i] as Array).size() > (_deck_pick_decks[widest - 1] as Array).size():
			widest = i + 1
	_deck_pick_slot = widest
	_refresh_deck_pick_preview()
	_layout_deck_pick_panel()
	_on_deck_pick_tab(1)

# 点卡组1/2/3：切换到该槽并刷新队伍预览
func _on_deck_pick_tab(slot: int) -> void:
	_deck_pick_slot = slot
	for s in _deck_pick_tabs.keys():
		var t: Button = _deck_pick_tabs[s]
		t.set_pressed_no_signal(int(s) == slot)
	_refresh_deck_pick_preview()
	_layout_deck_pick_panel()

# 重建当前卡组的队伍预览（清空旧内容后按当前槽重建）
func _refresh_deck_pick_preview() -> void:
	if _deck_pick_preview == null:
		return
	for c in _deck_pick_preview.get_children():
		_deck_pick_preview.remove_child(c)
		c.queue_free()
	var idx := _deck_pick_slot - 1
	var ids: Array = _deck_pick_decks[idx] if (idx >= 0 and idx < _deck_pick_decks.size()) else []
	if _deck_pick_start_btn != null:
		_deck_pick_start_btn.text = "用卡组 %d 出战" % _deck_pick_slot
	if ids.size() == 0:
		if _deck_pick_info != null:
			_deck_pick_info.text = "卡组 %d：空 —— 请到普通模式编辑页添加英雄。" % _deck_pick_slot
		_deck_pick_preview.custom_minimum_size = Vector2.ZERO
		_deck_pick_preview.size = Vector2.ZERO
		return
	if _deck_pick_info != null:
		_deck_pick_info.text = "卡组 %d（%d 名）%s" % [_deck_pick_slot, ids.size(), "" if ids.size() >= 5 else "  ⚠ 不足 5 名"]
	var pool := _make_deck_preview_cards(ids)
	_deck_pick_preview.add_child(pool)
	# 宿主要撑到队伍卡行的实际尺寸，否则面板宽度不随人数变化、卡牌会溢出面板
	_deck_pick_preview.custom_minimum_size = pool.custom_minimum_size
	_deck_pick_preview.size = pool.custom_minimum_size

# 卡组三选一界面的英雄卡块（与编辑页"卡组预览"同一套外观），悬停查看英雄属性
#   【2026-09-28·用户要求①】「卡组英雄队伍列表放大，8 个英雄占满宽度」：原来固定半径 30（8 个英雄只占半屏）；
#   【2026-09-28·用户要求②】「六边形改成 2 排、一排 4 个」⇒ 走 `_make_hex_pool` 的**网格模式**
#     （`single_row = false`：固定 **4 列**、**列优先**填充 ⇒ 8 名正好 4×2；5~8 名都是这个 4×2 蜂窝块）。
#   【2026-09-28·用户要求③】「太大了，把棋盘都挡住了」⇒ 半径**封顶 56**（沿用"一行版"那个大家都认可的卡大小）：
#     4 列要铺满宽度得 `r ≈ 96`，那样弹窗高 640、整块把棋盘盖住；封顶后块只有 364×291 ⇒ 弹窗小一圈、两侧透出棋盘。
#   半径 = `clampf(可用宽 / 6.5, 24, 56)`：窄屏按比例缩，宽屏由 56 兜住。想再小/再大只改这个上限
#   （48 更紧凑 / 64 更大）。可用宽 = 视口宽 − 80（面板最大宽是 `vsize.x − 24`，这里留出面板左右内边距）。
func _make_deck_preview_cards(ids: Array) -> Control:
	var hover_cb := func(hid: String):
		if hid == "":
			_set_score_tooltip_visible(false)
		else:
			_set_score_tooltip_hero(hid)
	var click_cb := func(_hid: String):
		pass
	var avail: float = get_viewport().get_visible_rect().size.x - 80.0
	# 4 列网格（列优先 ⇒ 8 名正好 4×2）；半径封顶 56（见上面函数头注释：96 会挡住棋盘）
	var rad := clampf(avail / 6.5, 24.0, 56.0)
	return _make_hex_pool(ids, hover_cb, click_cb, false, "", false, rad)

# 面板尺寸/位置。
# 【2026-09-23 修·用户报"点击卡组切换后弹窗会左右移动"】宽度/高度**只在第一次调用时量一次**
#   （那次的内容 = 人最多的卡组 + 最宽形态的限时大字，见 `_show_deck_pick_panel`）⇒ 之后切卡组
#   只换预览内容、尺寸与位置都不动。原来每次都按当前内容重算并重新居中 ⇒ 卡行人头数不同 /
#   秒数从两位数变一位数 ⇒ 宽度一变，居中的弹窗就整体左移或右移。
#   ⚠️ 量之前必须把 `custom_minimum_size` 清成 0：`reset_size()` 只重置 size，
#   `get_combined_minimum_size()` 仍会被上一轮写进去的 custom_minimum_size 垫高 ⇒ 宽度只增不减。
func _layout_deck_pick_panel() -> void:
	if _deck_pick_panel == null or not is_instance_valid(_deck_pick_panel):
		return
	var vsize := get_viewport().get_visible_rect().size
	var max_w: float = maxf(vsize.x - 24.0, 400.0)
	if _deck_pick_panel_w <= 0.0:
		_deck_pick_panel.custom_minimum_size = Vector2.ZERO
		_deck_pick_panel.reset_size()
		var min_sz := _deck_pick_panel.get_combined_minimum_size()
		_deck_pick_panel_w = clampf(maxf(min_sz.x, 400.0), 400.0, max_w)
		_deck_pick_panel_h = minf(min_sz.y, vsize.y - 16.0)
	var pw: float = clampf(_deck_pick_panel_w, 400.0, max_w)
	var ph: float = minf(_deck_pick_panel_h, vsize.y - 16.0)
	_deck_pick_panel.custom_minimum_size = Vector2(pw, ph)
	_deck_pick_panel.size = Vector2(pw, ph)
	_deck_pick_panel.position = Vector2((vsize.x - pw) / 2.0, maxf((vsize.y - ph) / 2.0, 8.0))

# 点"用卡组 N 出战"：取当前查看的卡组
func _on_deck_pick_confirm() -> void:
	_try_pick_deck(_deck_pick_slot)

# 点某卡组槽出战：不足 5 名则弹提示并保持面板
func _try_pick_deck(slot: int, ids_override: Array = []) -> void:
	var idx := slot - 1
	var ids: Array = ids_override
	if ids.is_empty() and idx >= 0 and idx < _deck_pick_decks.size():
		ids = _deck_pick_decks[idx]
	if ids.size() < 5:
		var d := AcceptDialog.new()
		d.title = "卡组人数不足"
		d.dialog_text = "卡组 %d 只有 %d 名英雄，至少需要 5 名才能出战。\n请到编辑页补足卡组，或点「随机英雄」。" % [slot, ids.size()]
		d.ok_button_text = "知道了"
		d.confirmed.connect(d.queue_free)
		add_child(d)
		d.popup_centered()
		return
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		battle._on_deck_pick(slot)

func _on_deck_pick_random_pressed() -> void:
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		battle._on_deck_pick_random()

func _close_deck_pick_panel() -> void:
	if _deck_pick_overlay != null:
		_deck_pick_overlay.queue_free()
		_deck_pick_overlay = null
	_deck_pick_panel = null
	_deck_pick_panel_w = 0.0   # 【2026-09-23】尺寸缓存随面板一起清（下次开面板重新量一次）
	_deck_pick_panel_h = 0.0
	_deck_pick_preview = null
	_deck_pick_info = null
	_deck_pick_start_btn = null
	_deck_pick_timer_label = null   # 【2026-09-21】限时大字随面板一起释放
	_deck_pick_tabs.clear()
	_deck_pick_decks = []
	_set_score_tooltip_visible(false)

# 下方常驻队伍面板：整支卡组（上阵 + 替补），一字行透明卡牌，随 team_updated 刷新。
# 同一面板双模式（避免"替补选人面板"与常驻面板重叠/互相遮盖）：
#  - 平时：只读展示本端替补席/队伍，悬停查看属性；
#  - SUBSTITUTING / PLACE_SUB：同一面板变"选择替补上阵"，点击英雄=选中落位（battle._on_sub_pick）。
func _refresh_team_panel() -> void:
	if battle == null:
		return
	if _in_replay():
		_close_team_panel()   # 回放里不摆常驻队伍卡（见 `_in_replay()` 的说明）
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
	if picking:
		# 自由部署双控：可能是"敌方替补列表"（拖动敌方英雄撤下后弹出），标题要标明是谁的替补
		var sub_txt: String = battle._sub_faction_txt()
		if sub_txt != "":
			title.text = "选择替补上阵（%s）：点击英雄选中，再点击棋盘绿格落位" % sub_txt
		else:
			title.text = "选择替补上阵（点击英雄选中，再点击棋盘绿格落位）"
	else:
		title.text = "替补队伍"
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
	# 【2026-09-28·用户要求】「卡组英雄队伍列表放大，8 个英雄占满宽度」：这一行原来固定半径 48
	#   （8 张只占 600/720 ≈ 83%）⇒ 改成**按可用宽度反算**：一行 n 张平顶六边形总宽 = `2r + (n−1)·1.5r`
	#   ⇒ `r = 可用宽 / (2 + 1.5·(n−1))`；可用宽 = 视口宽 − 面板左右内边距(6+6)与 20 的余量 − 两侧留白。
	#   ⚠️ 8 张一行的**物理上限**就是 `视口宽 / 12.5`（≈57）⇒ 再大必须改成两行，见下面 `_TEAM_ROW_MAX_R` 注释。
	var tn := maxi(ids.size(), 1)
	var tavail: float = maxf(vsize.x - 44.0, 320.0)
	var trad := minf(_TEAM_ROW_MAX_R, maxf(tavail / (2.0 + float(tn - 1) * 1.5), 18.0))
	var pool := _make_hex_pool(ids, hover_cb, click_cb, false, battle._pending_sub if picking else "", true, trad)
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
	_ui_root = root   # 【2026-09-23】给浮层用：临时遮罩要插在它**最底层**，别盖住常驻按钮（见 `_show_deck_pick_panel`）

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
	# 联机对局这两行还要显示双方姓名（我方=本机名片姓名 / 敌方=对端姓名），
	# 字号收一档（27→18）免得和中间的"第 N 回合 / 剩余时间"挤在一起。
	# 【2026-09-23 改】每侧 = 名字 + 逐槽 DeathMark（不是拼字符串）⇒ 空圈与骷髅同尺寸、单槽可定位/摇晃。
	var death_font := 18 if GameState.is_online else 27
	var slot_n: int = battle.LOSS_DEATH_COUNT if battle != null else 3
	_my_death_name = Label.new()
	_my_death_name.add_theme_font_size_override("font_size", death_font)
	_my_death_name.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
	_my_death_name.text = "我方"
	_my_death_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_my_death_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var my_row := HBoxContainer.new()
	my_row.add_theme_constant_override("separation", 7)
	my_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	my_row.position = Vector2(12, 11)
	my_row.size = Vector2(vsize.x * 0.5, DeathMark.SLOT_D)   # 高度跟着槽走（BEGIN 对齐，从 x=12 起排）
	root.add_child(my_row)
	my_row.add_child(_my_death_name)
	_my_marks.clear()
	for i in slot_n:
		var mk := DeathMark.new(Color(0.5, 0.85, 1.0))
		my_row.add_child(mk)
		_my_marks.append(mk)
	_op_death_name = Label.new()
	_op_death_name.add_theme_font_size_override("font_size", death_font)
	_op_death_name.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	_op_death_name.text = "敌方"
	_op_death_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_op_death_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 右侧整行贴右缘（图标在前、名字在后，与原来的 "☠☠☠ 敌方" 同一观感）
	var op_row := HBoxContainer.new()
	op_row.add_theme_constant_override("separation", 7)
	op_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	op_row.alignment = BoxContainer.ALIGNMENT_END
	op_row.size = Vector2(vsize.x - 12, DeathMark.SLOT_D)
	op_row.position = Vector2(0, 11)
	root.add_child(op_row)
	_op_marks.clear()
	for i in slot_n:
		var mk2 := DeathMark.new(Color(1.0, 0.5, 0.5))
		op_row.add_child(mk2)
		_op_marks.append(mk2)
	op_row.add_child(_op_death_name)
	# 阵亡演出层：加在状态栏之后 ⇒ 同 z_index 下画在状态栏之上（弹窗类浮层是更晚 join 的，仍在其上）
	_death_fx = DeathFx.new()
	_death_fx.z_index = 0
	add_child(_death_fx)
	_refresh_deaths()

	# 右上角暂停键（仅单机对局显示；联机不可暂停）：
	# 放在**状态栏下方**（y=60，状态栏高 54），不挤占顶部状态栏。
	_pause_btn = Button.new()
	_pause_btn.text = "暂停"
	_pause_btn.add_theme_font_size_override("font_size", 15)
	_pause_btn.custom_minimum_size = Vector2(50, 30)
	_pause_btn.pressed.connect(_on_pause_pressed)
	root.add_child(_pause_btn)
	# 按实际尺寸贴右边缘定位（主题内边距会让按钮比 custom_minimum_size 略大，
	# 用设定值定位会溢出屏幕右缘）
	_pause_btn.reset_size()
	_pause_btn.position = Vector2(vsize.x - _pause_btn.size.x - 6.0, 60.0)

	# 【2026-09-28·用户要求】联机：**右上角「认输」**（与「暂停」同一个角落/尺寸 —— 联机没有暂停，
	#   两个按钮互斥显示，见 `_refresh_controls()`）。点一下先喊一句完整的话给对端，再走认输结算。
	_surrender_btn = Button.new()
	_surrender_btn.text = "认输"
	_surrender_btn.add_theme_font_size_override("font_size", 15)
	_surrender_btn.custom_minimum_size = Vector2(50, 30)
	_surrender_btn.pressed.connect(_on_surrender_pressed)
	root.add_child(_surrender_btn)
	_surrender_btn.reset_size()
	_surrender_btn.position = Vector2(vsize.x - _surrender_btn.size.x - 6.0, 60.0)

	# 底部常驻按钮行：**只剩「结束回合」**（居中）。「重开 / 返回选人」整合进暂停面板（2026-09-27 用户要求）；
	#   联机的「返回大厅」也已删（2026-09-28 用户要求）⇒ 两种模式的底部行现在一样，联机退出走右上角「认输」。
	var btn_row := HBoxContainer.new()
	btn_row.position = Vector2((vsize.x - 390) / 2.0, vsize.y - END_BTN_IMG_H - 10)
	btn_row.size = Vector2(390, END_BTN_IMG_H)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	root.add_child(btn_row)

	var end_tex := load(END_TURN_TEX) as Texture2D
	var end_btn := Button.new()
	end_btn.custom_minimum_size = Vector2(190, 52)
	end_btn.add_theme_font_size_override("font_size", 19)
	end_btn.add_theme_color_override("font_color", Color(0.1, 0.08, 0.02))
	if end_tex != null:
		# 图 = 按钮本体（文案画在图里）⇒ 清空 text；四个状态共用这张图（悬停更亮 / 按下更暗 / 禁用压暗）。
		# **不能只改 normal**：不改的话悬停·按下·禁用会掉回主题默认样式（灰蓝方块），看着像换了个按钮。
		end_btn.text = ""
		end_btn.custom_minimum_size = Vector2(
				END_BTN_IMG_H * float(end_tex.get_width()) / float(end_tex.get_height()), END_BTN_IMG_H)
		end_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var end_states := {
			"normal": Color(1.0, 1.0, 1.0, 1.0),
			"hover": Color(1.10, 1.10, 1.10, 1.0),
			"pressed": Color(0.84, 0.84, 0.84, 1.0),
			"disabled": Color(0.55, 0.55, 0.58, 0.85),
		}
		for state in end_states.keys():
			var sb := StyleBoxTexture.new()
			sb.texture = end_tex
			sb.modulate_color = end_states[state]
			end_btn.add_theme_stylebox_override(String(state), sb)
	else:
		# 图缺失：保持原来的金色文字按钮（安全退回，不影响可玩性）
		end_btn.text = "结束回合"
		var end_sb := StyleBoxFlat.new()
		end_sb.bg_color = Color(0.75, 0.55, 0.15, 1.0)
		end_sb.corner_radius_top_left = 12
		end_sb.corner_radius_top_right = 12
		end_sb.corner_radius_bottom_left = 12
		end_sb.corner_radius_bottom_right = 12
		end_sb.set_border_width_all(2)
		end_sb.border_color = Color(1.0, 0.9, 0.5)
		end_btn.add_theme_stylebox_override("normal", end_sb)
	end_btn.pressed.connect(_on_end_turn)
	# 【2026-09-27·用户要求】结束回合**不要骰子**悬停效果（按钮本体就是那张图）。
	#   `detach()` 会打 `no_dice` 标记 ⇒ 之后重新入树/重建也不会再挂上来；重复调用无副作用。
	UiDice.detach(end_btn)
	btn_row.add_child(end_btn)
	_end_btn = end_btn

	# 【2026-09-27 用户报「刚进录像会有黄色字体弹出，被蓝方回合盖住」】建顶栏时就分清是不是回放局：
	#   回放局一进来就直接写"第 N 回合 · 蓝方/红方回合"，**不留那一帧**黄色对局文案（`_set_round_text(1, true)`
	#   会先写成"第 1 回合 · 你的回合"，回放里那句话既不对、又会被随后的横幅盖住 → 一闪而过看着很脏）。
	if GameState.replay_id != "":
		_round_label.text = "第 %d 回合 · %s" % [GameState.round_number,
			"蓝方回合" if GameState.active_side == GameState.SIDE_PLAYER else "红方回合"]
		_round_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
		_top_fit_key = ""
		_fit_top_center()
	else:
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
	# 【2026-09-21 修·四个角红色重叠】原来上/下两条是**整屏宽**、左/右两条是**整屏高** ⇒
	# 四个角各被"横条 + 竖条"叠了两次，alpha 0.5 叠成 0.75，四个角出现更深的红方块（用户报的现象）。
	# 现在左/右两条只占**扣掉上下条之后**的那段高度：四角不叠、也不留缝，整圈 alpha 一致。
	var mid_h := maxf(vsize.y - edge * 2.0, 0.0)
	var bars := [
		[Vector2(0, 0), Vector2(vsize.x, edge)],               # 上
		[Vector2(0, vsize.y - edge), Vector2(vsize.x, edge)],  # 下
		[Vector2(0, edge), Vector2(edge, mid_h)],              # 左（避开上下条，不再压角）
		[Vector2(vsize.x - edge, edge), Vector2(edge, mid_h)],  # 右（同上）
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
	"快点吧，我等的花儿都谢了",
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
		_close_chat_panel()
		return
	var vsize := get_viewport().get_visible_rect().size
	# 全屏透明层：点"面板以外"的任意位置即收起（面板内的点击由面板/按钮自己吃掉，不会传到这一层）
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_chat_overlay_input)
	add_child(overlay)
	_chat_overlay = overlay
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
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
	overlay.add_child(panel)
	_chat_panel = panel   # 先登记：连点两下"喊话"不会叠出第二个面板
	await get_tree().process_frame
	if not is_instance_valid(panel):   # 这一帧内已被收起（点外部/切阶段）：不再定位
		return
	# 面板尺寸与定位用**同一个高度**：先按内容最小高度定死尺寸，再以它往上推，
	# 保证面板底边永远停在"喊话"按钮上沿之上（按钮高度受主题内边距影响，不硬编码）。
	var pmin := panel.get_combined_minimum_size()
	panel.size = Vector2(maxf(pw, pmin.x), pmin.y)
	var btn_top := vsize.y - 56.0 - 10.0
	if _chat_btn != null and is_instance_valid(_chat_btn):
		btn_top = _chat_btn.position.y
	panel.position = Vector2(10, maxf(6.0, btn_top - pmin.y - 6.0))

func _send_chat(txt: String) -> void:
	_close_chat_panel()
	if battle != null and is_instance_valid(battle):
		battle.send_quick_chat(txt)
		_show_chat_bubble(txt, true)   # 自己发的喊话本端也立刻回显（我方侧），不必等对端

func _close_chat_panel() -> void:
	if _chat_panel != null and is_instance_valid(_chat_panel):
		_chat_panel.queue_free()
	_chat_panel = null
	if _chat_overlay != null and is_instance_valid(_chat_overlay):
		_chat_overlay.queue_free()
	_chat_overlay = null

# 点选言面板以外的任意位置（全屏层拦到）即收起。
# 与音量弹层一致：只处理鼠标左键——触摸在安卓/iOS 由 Godot 转成鼠标事件，再判触摸会双触发。
func _on_chat_overlay_input(ev: InputEvent) -> void:
	var mb := ev as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_close_chat_panel()

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

## 【2026-09-27·录像回放】刷新顶部"第 N 回合 · 蓝方/红方回合"。回放里没有 `round_changed`／
## `active_side_changed` 这些信号（`_refresh_round()` 因此不会自己重画），换段/跳段后由 Battle 喊一次。
func refresh_round_label() -> void:
	_set_round_text(GameState.round_number, true)

func _set_round_text(round_num: int, _player_side: bool) -> void:
	# 联机视角：本端操作的是"我方"，另一方是"敌方"。用 battle._my_side() 判断本端是否当前行动方。
	var my_turn := true
	if battle != null:
		if GameState.dual_control:
			# 自由部署双控：当前行动方都由本端操控，但状态栏仍要如实显示当前是谁的回合（敌方行动=敌方回合）
			my_turn = battle.side_faction(GameState.active_side) == battle._my_faction()
		else:
			my_turn = GameState.active_side == battle._my_side()
	# 非回合阶段（开局部署/竞技场选人/替补中）不声称"你的回合/敌方回合"：
	# 否则对方先部署/先手时顶部仍错误显示"你的回合"。
	var phase_txt := ""
	if battle != null and is_instance_valid(battle) and not _in_replay():
		if battle.state == Battle.State.ARENA_DRAFT:
			phase_txt = "竞技场选人"
		elif battle.state == Battle.State.DECK_PICK:
			phase_txt = "选择卡组"
		elif battle.state == Battle.State.DEPLOY or battle.state == Battle.State.PLACE_DEPLOY:
			phase_txt = "部署选人"
		elif battle.state == Battle.State.SUBSTITUTING or battle.state == Battle.State.PLACE_SUB:
			phase_txt = "替补"
	var side := phase_txt if phase_txt != "" else ("你的回合" if my_turn else "敌方回合")
	if _in_replay():
		# 回放：说"蓝方/红方"（用户要求），且按**正在播的那一段**判（`active_side` 是录像里的值，不能用）
		var rs: int = battle.replay_side_of(battle._replay_frame)
		if rs < 0:
			# 【2026-09-28 用户报「部署阶段的提示有问题」】部署那一帧（side = -1）不是任何一方的回合
			side = "部署"
			my_turn = true
		else:
			my_turn = rs == GameState.SIDE_PLAYER
			side = "蓝方回合" if my_turn else "红方回合"
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
	_top_fit_key = ""          # 文字/火焰都变了 ⇒ 强制重算一次中间那组的字号
	_fit_top_center()

## 【2026-09-27·用户报「战斗中状态栏在 11 回合后，显示会挤到一起」】顶部中间那组
##   （`第 N 回合 · 阵营` + 火焰 + 剩余时间）是**整条居中**排的，而左右两侧的阵亡计数行是**绝对定位**
##   （左侧从 x=12 起排、右侧贴右缘）⇒ 三件事叠加后中间这组会压到两侧：
##     ① 回合数变成两位数（第 10 回合起多一个字）② **第 11 回合火焰亮起**（+34px）③ 剩余时间也在这组里。
##   这里按"两侧行的**实际内容宽度**"算出中间还剩多少，再**逐档缩字号**（24 → 22 → 20 → 18）、
##   必要时把火焰收小，直到放得下。⚠️ 纯布局：**不改任何文案**（不给自己加字/减字）。
##   很便宜，但没必要每帧算 ⇒ 用 `_top_fit_key`（文字+火焰状态）挡重复调用。
func _fit_top_center() -> void:
	if _round_label == null or not is_instance_valid(_round_label):
		return
	var flame_on: bool = _flame_icon != null and is_instance_valid(_flame_icon) and _flame_icon.visible
	var timer_on: bool = _turn_timer_label != null and is_instance_valid(_turn_timer_label) and _turn_timer_label.visible
	var key := "%s|%s|%s|%.0f" % [_round_label.text, (_turn_timer_label.text if timer_on else ""),
		str(flame_on), get_viewport().get_visible_rect().size.x]
	if key == _top_fit_key:
		return
	_top_fit_key = key
	var vsize := get_viewport().get_visible_rect().size
	var lw := 0.0
	var rw := 0.0
	if _my_death_name != null and is_instance_valid(_my_death_name) and _my_death_name.get_parent() is Control:
		lw = (_my_death_name.get_parent() as Control).get_combined_minimum_size().x
	if _op_death_name != null and is_instance_valid(_op_death_name) and _op_death_name.get_parent() is Control:
		rw = (_op_death_name.get_parent() as Control).get_combined_minimum_size().x
	var avail := vsize.x - lw - rw - 28.0        # 两侧各留 12px 起排缝 + 4px 余量
	var sep := 4.0
	if _round_label.get_parent() is HBoxContainer:
		sep = float((_round_label.get_parent() as HBoxContainer).get_theme_constant("separation"))
	var font := _round_label.get_theme_font("font")
	var outline := float(_round_label.get_theme_constant("outline_size"))
	var need := func(fs: int, fw: float) -> float:
		var w := font.get_string_size(_round_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + outline * 2.0
		if flame_on:
			w += sep + fw
		if timer_on:
			var tf := _turn_timer_label.get_theme_font("font")
			w += sep + tf.get_string_size(_turn_timer_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				_turn_timer_label.get_theme_font_size("font_size")).x
		return w
	var fs_use := 18
	for fs in [24, 22, 20, 18]:
		if float(need.call(int(fs), 34.0)) <= avail:
			fs_use = int(fs)
			break
	_round_label.add_theme_font_size_override("font_size", fs_use)
	if flame_on:
		var fw := 34.0
		if float(need.call(fs_use, fw)) > avail:
			fw = 26.0
		if float(need.call(fs_use, fw)) > avail:
			fw = 20.0
		_flame_icon.custom_minimum_size = Vector2(fw, fw)
		_flame_icon.size = Vector2(fw, fw)
		_flame_icon.set("size_px", fw * 0.76)

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

# 阵亡计数图标（骷髅）= 已阵亡，空心圆 = 尚未阵亡
# 【2026-09-23 改·用户要求】"标志出现"的时机 = **卡面飞行的卡片落地那一刻**，不是死亡瞬间：
#   真实阵亡数（战斗逻辑，判负/替补都读它）先涨 ⇒ 这里把它记进 `_reveal_pending`，
#   由 `_on_unit_dying` 播的 DeathFx 在落地回调里 `_reveal_mark()` 才点亮槽 + 摇晃。
#   ⚠️ headless（跑批/无窗口）不发 `dying`、也不会有 pending ⇒ 本函数立刻就点亮，**与改动前逐位一致**。
#   视角化与原来一致：联机客户端左右对调（用 `battle._my_dead()/_opp_dead()`，它们已经做过视角映射）。
func _refresh_deaths() -> void:
	if battle == null:
		return
	var my_dead: int = battle._my_dead()
	var op_dead: int = battle._opp_dead()
	# 重开/新局/被清零：槽位与 pending 一起归位（否则会残留上一局的骷髅）
	# ⚠️ 判据只看**已点亮**的槽数（不看 pending）：死亡瞬间 `dying` 会把 pending +1，而真实计数要
	#   0.3s 后才涨（`died`）⇒ 若把 pending 算进来，这 0.3s 里就会误判成"被清零"、把 pending 抹掉。
	if my_dead < int(_mark_filled["my"]):
		_reveal_pending["my"] = 0
		_set_marks_filled("my", my_dead)
	if op_dead < int(_mark_filled["op"]):
		_reveal_pending["op"] = 0
		_set_marks_filled("op", op_dead)
	# 真实数 > 已点亮 + 待点亮 ⇒ 多出来的先挂 pending（等特效落地；特效不存在时下一行会立刻补上）
	if my_dead > int(_mark_filled["my"]) + int(_reveal_pending["my"]):
		_reveal_pending["my"] = my_dead - int(_mark_filled["my"])
	if op_dead > int(_mark_filled["op"]) + int(_reveal_pending["op"]):
		_reveal_pending["op"] = op_dead - int(_mark_filled["op"])
	# 没有特效在飞的（headless / 特效被跳过 / 场景刚恢复）⇒ 立刻补齐，别让标志一直不出现
	if _death_fx == null or not is_instance_valid(_death_fx) or _death_fx.get_child_count() == 0:
		while int(_reveal_pending["my"]) > 0:
			_reveal_mark("my", false)
		while int(_reveal_pending["op"]) > 0:
			_reveal_mark("op", false)
	# 联机对局：两侧文字=双方姓名（我方=本机名片，敌方=对端；对端没发姓名时写"对方"）；单机写"我方/敌方"
	var my_txt := "我方"
	var op_txt := "敌方"
	if GameState.is_online:
		my_txt = Stats.display_name()
		op_txt = GameState.net_peer_name if GameState.net_peer_name != "" else "对方"
	if my_txt != _last_my_text and _my_death_name != null:
		_my_death_name.text = my_txt
		_last_my_text = my_txt
	if op_txt != _last_op_text and _op_death_name != null:
		_op_death_name.text = op_txt
		_last_op_text = op_txt

# 直接把某侧槽位按真实数归位（不播摇晃；重开/新局/读档恢复时用）
func _set_marks_filled(side: String, n: int) -> void:
	var marks: Array = _my_marks if side == "my" else _op_marks
	for i in marks.size():
		var mk: DeathMark = marks[i]
		if mk != null and is_instance_valid(mk):
			mk.set_filled(i < n)
	_mark_filled[side] = clampi(n, 0, marks.size())

# 点亮一个槽（`shake` = 播"标志出现 + 摇晃"；headless/补账时传 false 只置位）
func _reveal_mark(side: String, shake := true) -> void:
	var marks: Array = _my_marks if side == "my" else _op_marks
	var idx := int(_mark_filled[side])
	if idx < 0 or idx >= marks.size():
		_reveal_pending[side] = 0
		return
	var mk: DeathMark = marks[idx]
	_mark_filled[side] = idx + 1
	_reveal_pending[side] = maxi(int(_reveal_pending[side]) - 1, 0)
	if mk == null or not is_instance_valid(mk):
		return
	mk.set_filled(true)
	if shake:
		mk.pop_and_shake()

# 取该侧"下一个要出现的"标记槽（DeathFx 用它当飞行终点；槽还没出现也能拿到位置 ✓ 固定尺寸）
func _next_mark(side: String) -> Control:
	var marks: Array = _my_marks if side == "my" else _op_marks
	var idx := int(_mark_filled[side]) + int(_reveal_pending[side])
	if idx < 0 or idx >= marks.size():
		idx = marks.size() - 1
	if idx < 0:
		return null
	return marks[idx]

# 【2026-09-23 新增·用户要求】死亡瞬间：播"卡面破碎升天 → 飞向顶部阵亡标志 → 标志出现并摇晃"。
#   阵营 → 左/右那排标记：用 `battle._my_faction()`（联机客户端自动左右对调，与 `_refresh_deaths` 同口径）。
#   召唤物（骷髅兵等）：`DataRegistry.summons.has()` ⇒ 只破碎升天、不占阵亡标志位（传 target=null）。
func _on_unit_dying(u: Unit) -> void:
	if u == null or not is_instance_valid(u):
		return
	if _death_fx == null or not is_instance_valid(_death_fx):
		return
	var side := "my" if u.faction == battle._my_faction() else "op"
	var is_summon: bool = DataRegistry.summons.has(u.hero_id)
	# 死亡位置 → 屏幕坐标（单位在世界画布上；HUD 这一层没有位移 ⇒ 可直接当本层坐标用）
	var start: Vector2 = u.get_global_transform_with_canvas().origin
	var col := Color(0.5, 0.85, 1.0) if side == "my" else Color(1.0, 0.5, 0.5)
	var target: Control = null if is_summon else _next_mark(side)
	# pending 先 +1：真实计数马上会涨（`_on_unit_died` 在 0.3s 后），这样 `_refresh_deaths` 不会提前点亮
	if not is_summon:
		_reveal_pending[side] = int(_reveal_pending[side]) + 1
	var fx := DeathFx.new()
	_death_fx.add_child(fx)
	fx.play(start, target, col, func(): _reveal_mark(side, true))

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
	_update_deck_pick_timer()
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

# 【2026-09-21 用户定】选卡组面板的限时大字：读 `battle.deck_pick_time_left`（15 秒，超时随机选一个）。
# 已选定（联机在等对端）或面板不在 DECK_PICK ⇒ 清空不显示。
func _update_deck_pick_timer() -> void:
	if _deck_pick_timer_label == null or not is_instance_valid(_deck_pick_timer_label):
		return
	if battle == null or not is_instance_valid(battle):
		return
	if battle.state != Battle.State.DECK_PICK or battle.deck_pick_time_left <= 0.0:
		_deck_pick_timer_label.text = ""
		return
	var secs := int(ceil(battle.deck_pick_time_left))
	_deck_pick_timer_label.text = "%d 秒（超时随机选一个卡组）" % secs
	_deck_pick_timer_label.add_theme_color_override("font_color",
		Color(1.0, 0.3, 0.25) if secs <= 5 else Color(1.0, 0.9, 0.4))

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
	_fit_top_center()          # 【2026-09-27】倒计时的文字/显隐也在中间那组里 ⇒ 跟着重算一次（内部有去重）

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
## 本局是否在放录像（`Battle._replay_mode`）。回放里战场按钮全部收起 —— 用户 2026-09-27 报
## 「怎么录像功能可以点击下方的按钮」：回放本来就不该有"结束回合/重开/返回选人"这些入口，
## 退出回放走回放控制条自己的「返回」。
## 【录像回放】进回放时把"临时提示"一次清干净：回合横幅（含还在淡出的）、部署面板、常驻队伍面板。
## 由 `Battle._replay_begin()` 调用；对局路径不调（一个字不变）。
func clear_transient_ui() -> void:
	if _turn_banner_tween != null and _turn_banner_tween.is_valid():
		_turn_banner_tween.kill()
	if _turn_banner != null and is_instance_valid(_turn_banner):
		_turn_banner.queue_free()
	_turn_banner = null
	_close_deploy_panel()
	_close_team_panel()

func _in_replay() -> bool:
	# ⚠️ 除了 `Battle._replay_mode`，还要看 `GameState.replay_id`：回放分支里 **HUD 先建、`_replay_mode` 后置**
	#   （`_replay_begin()` 的顺序），中间那段空窗期里 `state` 还是录像里残留的 `DEPLOY` ⇒ 部署面板会被建出来
	#   （用户报的"黄字、什么部署什么的"就是这么漏的，实测：`_show_deploy_panel：replay=false state=4`）。
	return GameState.replay_id != "" \
			or (battle != null and is_instance_valid(battle) and bool(battle._replay_mode))

func _refresh_controls() -> void:
	if _in_replay():
		if _end_btn != null:
			_end_btn.visible = false
		if _surrender_btn != null:
			_surrender_btn.visible = false
		if _pause_btn != null:
			_pause_btn.visible = false   # 回放用控制条的「暂停/继续」（对局暂停是 tree.paused，会把回放一起冻住）
		return
	var my_turn := false
	if battle != null:
		if GameState.dual_control:
			# 自由部署双控：当前行动方都由本端操控(已在 _begin_side 设为 PLAYER_INPUT)，可结束回合
			my_turn = battle.state == Battle.State.PLAYER_INPUT
		else:
			my_turn = battle.state == Battle.State.PLAYER_INPUT and GameState.active_side == battle._my_side()
	if _end_btn != null:
		_end_btn.disabled = not my_turn
	if _pause_btn != null:
		_pause_btn.visible = not GameState.is_online   # 暂停仅单机（联机暂停会与对端不同步）
	if _surrender_btn != null:
		# 【2026-09-28·用户要求】「认输」只在联机显示（与「暂停」同一角落、互斥）：
		#   联机没有暂停，退出入口就从底部那枚「返回大厅」换成这里。
		_surrender_btn.visible = GameState.is_online

# 【2026-09-28·用户要求】联机认输：先喊**完整的一句**给对端（本端也回显气泡），再走认输结算。
func _on_surrender_pressed() -> void:
	if battle == null or not is_instance_valid(battle):
		return
	_send_chat(battle.SURRENDER_LINE)
	battle.surrender_online()

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

# ---- 暂停（仅单机）：冻结整棵场景树，弹"已暂停"遮罩，可继续 ----
func _on_pause_pressed() -> void:
	if GameState.is_online:
		return   # 联机不可暂停（会影响与对端的同步）
	if _pause_overlay != null and is_instance_valid(_pause_overlay):
		return   # 已暂停
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	# 暂停后引擎不再处理 PAUSABLE 节点：遮罩与按钮必须能在暂停中工作
	overlay.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	add_child(overlay)
	_pause_overlay = overlay
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 1.0)   # 暂停时背景全黑（遮住棋盘）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	var panel := PanelContainer.new()
	# 面板外观走主题里的"弹出框边框"（theme/panel_frame_dark.png）
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "已暂停"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var hint := Label.new()
	hint.text = "对局已冻结（计时与动画都停下）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	var resume := Button.new()
	resume.text = "继续游戏"
	resume.add_theme_font_size_override("font_size", 20)
	resume.custom_minimum_size = Vector2(240, 50)
	resume.pressed.connect(_on_resume_pressed)
	vb.add_child(resume)
	# 【2026-09-27·用户要求】「重开 / 返回选人」已整合进暂停面板（底部常驻行只剩结束回合）：
	#   单机普通模式给这两个；**天梯**仍只给「保存并退出 / 放弃本次天梯」（重开会作废本局，口径冲突）。
	if GameState.ladder_mode != "":
		var save_quit := Button.new()
		save_quit.text = "保存并退出"
		save_quit.add_theme_font_size_override("font_size", 20)
		save_quit.custom_minimum_size = Vector2(240, 50)
		save_quit.pressed.connect(_on_ladder_save_quit)
		vb.add_child(save_quit)
		var give_up := Button.new()
		give_up.text = "放弃本次天梯"
		give_up.add_theme_font_size_override("font_size", 20)
		give_up.custom_minimum_size = Vector2(240, 50)
		give_up.pressed.connect(_on_ladder_give_up)
		vb.add_child(give_up)
		# 【2026-09-24 用户要求】原来按钮下面还有一块小字（"天梯普通模式 · 第 N 局 · 当前连胜 M 场" + 两行按钮说明）
		#   ⇒ 已删；暂停面板现在就三行：继续游戏 / 保存并退出 / 放弃本次天梯。
	else:
		var p_restart := Button.new()
		p_restart.text = "重开"
		p_restart.add_theme_font_size_override("font_size", 20)
		p_restart.custom_minimum_size = Vector2(240, 50)
		p_restart.pressed.connect(_on_restart)
		vb.add_child(p_restart)
		var p_back := Button.new()
		# 【2026-09-27·用户要求】普通模式暂停里的这个按钮 = **返回主菜单**（文案原写"返回选人"，
		#   但 `_on_back_to_menu` 走的就是 `change_scene_to_file(Menu.tscn)`、落点是主菜单页
		#   —— Menu 的组队页只有 `net_edit_mode` 才会直接进 ⇒ 这里只是把文案改成与实际一致）。
		p_back.text = "返回主菜单"
		p_back.add_theme_font_size_override("font_size", 20)
		p_back.custom_minimum_size = Vector2(240, 50)
		p_back.pressed.connect(_on_back_to_menu)
		vb.add_child(p_back)
	panel.reset_size()
	var pw: float = clampf(maxf(panel.get_combined_minimum_size().x, 300.0), 300.0, maxf(vsize.x - 40.0, 300.0))
	var ph: float = panel.get_combined_minimum_size().y
	panel.size = Vector2(pw, ph)
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0)
	get_tree().paused = true

func _on_resume_pressed() -> void:
	_resume()

# 【天梯·保存并退出】存档已经在"每次回合开始"落过盘了（见 `Battle._ladder_autosave()`），
#   这里只做两件事：确认手上这份快照确实在（没有就现补一份），然后回主菜单。
#   ⚠️ 补不补由 `Battle._ladder_can_save()` 判：**部署阶段要补**（快照含"已经上了哪几个人"，
#      续档时接着部署），选卡组 / 竞技场选人阶段不补（那会儿双方卡组都没定，没有可回的局面）。
#   本轮存档**保留** ⇒ 下次进天梯可以继续。
func _on_ladder_save_quit() -> void:
	if battle != null and not LadderStore.has_snapshot() and battle._ladder_can_save():
		battle._ladder_autosave(GameState.active_side)
	_resume()
	GameState.ladder_mode = ""
	GameState.arena_mode = false
	get_tree().change_scene_to_file("res://scenes/Menu.tscn")

# 【天梯·放弃】用户要求先**再确认**一次（这一步会清当前连胜 + 删本轮存档，误触代价太大）：
#   这里只负责弹确认层；真正确认后走 `_ladder_do_give_up()`。
func _on_ladder_give_up() -> void:
	if _ladder_confirm != null and is_instance_valid(_ladder_confirm):
		return
	var vsize := get_viewport().get_visible_rect().size
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_STOP
	# 暂停后引擎不再处理 PAUSABLE 节点：确认层与按钮必须能在暂停中工作（与暂停遮罩同一处理）
	ov.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	add_child(ov)
	_ladder_confirm = ov
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.75)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov.add_child(dim)
	var panel := PanelContainer.new()
	ov.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "确定放弃本次天梯？"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1, 0.6, 0.5))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	# ⚠️ 这里**不要**再加说明小字（用户 2026-09-24：「你不要自己乱加这种描述，显得很乱，需要的话我会让你加的」）
	var yes := Button.new()
	yes.text = "确定放弃"
	yes.add_theme_font_size_override("font_size", 20)
	yes.custom_minimum_size = Vector2(240, 50)
	yes.pressed.connect(_ladder_do_give_up)
	vb.add_child(yes)
	var no := Button.new()
	no.text = "取消"
	no.add_theme_font_size_override("font_size", 20)
	no.custom_minimum_size = Vector2(240, 50)
	no.pressed.connect(_close_ladder_confirm)
	vb.add_child(no)
	panel.reset_size()
	var pw: float = clampf(maxf(panel.get_combined_minimum_size().x, 320.0), 320.0, maxf(vsize.x - 40.0, 320.0))
	var ph: float = panel.get_combined_minimum_size().y
	panel.size = Vector2(pw, ph)
	panel.position = Vector2((vsize.x - pw) / 2.0, (vsize.y - ph) / 2.0)

func _close_ladder_confirm() -> void:
	if _ladder_confirm != null and is_instance_valid(_ladder_confirm):
		_ladder_confirm.queue_free()
	_ladder_confirm = null

# 【天梯·放弃】确认之后才真的执行：当前连胜清零、删档（最高连胜保留）
# 【2026-09-25 用户要求】不再直接回主菜单，而是**弹结算面板**：
#   「才X连胜，跑什么？去简单难度偷偷进步啊？」（X = 放弃那一刻的当前连胜）
#   ⚠️ 面板弹出期间**整棵树保持暂停**（`_resume()` 不在这里调）⇒ 战斗冻结，AI 不会在面板后面接着跑；
#      结算浮层自己按 `PROCESS_MODE_WHEN_PAUSED` 收输入（见 `show_result()`），点「返回主菜单」才真的换场景。
func _ladder_do_give_up() -> void:
	_close_ladder_confirm()
	GameState.ladder_final_streak = Stats.current_streak(Stats.current_mode_key())
	Stats.reset_streak(Stats.current_mode_key())
	LadderStore.finish_run()
	_ladder_gave_up = true
	show_result(false)

# 解除暂停（幂等）：收起遮罩并恢复场景树
func _resume() -> void:
	if _pause_overlay != null and is_instance_valid(_pause_overlay):
		_pause_overlay.queue_free()
	_pause_overlay = null
	if is_inside_tree():
		get_tree().paused = false

# 场景退出兜底：若在暂停中离开（返回选人等），务必恢复，避免整个引擎一直暂停。
# 这里**不能**用 get_tree()：节点被判离场景树时 get_tree() 会报 Parameter "data.tree" is null，
# 拿不到 SceneTree 就恢复不了暂停。Engine.get_main_loop() 与节点是否在树里无关，始终有效。
func _exit_tree() -> void:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).paused = false

func _on_end_turn() -> void:
	if battle and battle.state == Battle.State.PLAYER_INPUT:
		battle.submit_end_turn()

# redraft=true = 对局结束后"再战一局"（竞技场需重新 2 选 1 选人）；
# 对局中的"重开"用默认 false（竞技场沿用同队伍，普通模式重新选卡组）。
func _on_restart(redraft := false) -> void:
	_resume()   # 若正处于暂停：先恢复，否则重开流程全被冻结
	if _result_overlay != null:
		# 关闭结算浮层（场景不卸载，需手动收起，否则遮住重开的选人/部署界面）
		_result_overlay.queue_free()
		_result_overlay = null
	# 重开前收起棋盘下方的全部临时面板：常驻"替补队伍/替补选人"与开局部署面板。
	# 否则在替补阶段（SUBSTITUTING/PLACE_SUB）点重开时，reset_match 只重置战斗数据，
	# 已打开的面板不会随 deploy_refresh 收起，上一局的英雄行会残留在屏底。
	_close_team_panel()
	_close_deploy_panel()
	_close_arena_panel()     # 竞技场选人阶段重开：收掉 2 选 1 面板，避免残留挡住新一轮选人
	_close_deck_pick_panel()
	if battle != null and is_instance_valid(battle):
		if GameState.is_online:
			battle.request_rematch_online()   # 联机：请求再来一局（不退出连接/大厅）
		else:
			battle.reset_match(redraft)   # 重置本局（不卸载场景，避免 reload 打断异步导致 get_tree() null 崩溃）
	elif GameState.is_online:
		# 异常兜底（Battle 已失效）：退回联机大厅
		NetBus.stop()
		GameState.reset_online()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
	else:
		get_tree().reload_current_scene()

func show_result(win: bool) -> void:
	# 【2026-09-25】主动放弃天梯时**不能**解暂停（战斗要冻在面板后面）⇒ 只收掉暂停遮罩，保持 paused。
	if _ladder_gave_up:
		if _pause_overlay != null and is_instance_valid(_pause_overlay):
			_pause_overlay.queue_free()
		_pause_overlay = null
	else:
		_resume()   # 结算时确保不在暂停态（否则结算浮层按钮点不动）
	# 【2026-09-23 新增·配套阵亡演出】判负/判胜的那一刻（第 3 名阵亡后 0.3s）结算浮层就会弹出来，
	#   正好压在"卡面飞向阵亡标志"的演出上 ⇒ 若还有演出在飞，先等它落地再弹（只延迟面板，不改判定）。
	#   headless（跑批/无窗口）没有演出 ⇒ 这段不生效、时序与改动前逐位一致。
	if _death_fx != null and is_instance_valid(_death_fx) and _death_fx.get_child_count() > 0:
		await get_tree().create_timer(0.75).timeout
		if not is_inside_tree():
			return
	if _result_overlay != null:
		_result_overlay.queue_free()
	var vsize := get_viewport().get_visible_rect().size
	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	if _ladder_gave_up:
		# 放弃天梯：树是暂停的 ⇒ 面板必须能在暂停中收输入（与再确认层同一处理）。
		overlay.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
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
	sub.add_theme_font_size_override("font_size", 18)
	# 【2026-09-24 用户要求·天梯模式】结算面板显示连胜：赢了显示"当前连胜"（可点继续挑战）。
	# 【2026-09-25 用户要求·天梯失败面板】失败那一面**只留一句调侃**：
	#   用户原话「我方英雄阵亡达3名和下面那行去掉。最下面那行本轮已结束（...）也去掉。
	#   就写"才x连胜就不行了？你适合打简单难度"」⇒ sub 只写这一句、`qhint`（本轮已结束…）整块删掉。
	#   x = `GameState.ladder_final_streak`（失败那一刻的当前连胜，见 `Battle._ladder_on_match_result()`）。
	var ladder := GameState.ladder_mode != ""
	if ladder:
		var lk := Stats.current_mode_key()
		if win:
			sub.text = "%s · 当前连胜：%d 场" % [LadderStore.mode_name(), Stats.current_streak(lk)]
			sub.add_theme_color_override("font_color", Color(1, 0.86, 0.5))
		else:
			# 【2026-09-25 用户要求】0 连胜单独一句「你好歹赢一场啊」（打输 / 主动放弃都一样 —— 一场没赢，
			#   说"才0连胜"没意思）；有连胜才用下面两种调侃：
			#   打输 = 「才X连胜就不行了？你适合打简单难度」；主动放弃 = 「才X连胜，跑什么？去简单难度偷偷进步啊？」
			#   X 都是"结束那一刻的当前连胜"（= `GameState.ladder_final_streak`）。
			var st := GameState.ladder_final_streak
			if st <= 0:
				sub.text = "你好歹赢一场啊"
			elif _ladder_gave_up:
				sub.text = "才%d连胜，跑什么？去简单难度偷偷进步啊？" % st
			else:
				sub.text = "才%d连胜就不行了？你适合打简单难度" % st
			_ladder_gave_up = false
			sub.add_theme_color_override("font_color", Color(1, 0.7, 0.6))
	else:
		sub.text = "敌方英雄阵亡达 3 名。" if win else "我方英雄阵亡达 3 名。"
		sub.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

	box.add_child(_vspacer(12))

	# 【2026-09-24 用户要求·天梯模式】天梯里**不要**「重开 / 返回选人」这两个按钮
	#   （用户原话：「把天梯模式的重开和返回选人按钮删除」）⇒ 结算面板只留：
	#   赢了 =「继续挑战」+「保存并退出」；输了 = 本轮结束，只给「返回主菜单」（退出/结束走暂停界面那两个）。
	if ladder and win:
		var again := Button.new()
		again.text = "继续挑战"
		again.custom_minimum_size = Vector2(260, 52)
		again.add_theme_font_size_override("font_size", 20)
		again.pressed.connect(_on_restart.bind(true))   # 连胜继续，下一局重新选人/选卡组
		box.add_child(again)
		# 【2026-09-24 用户要求·补】胜利面板也要能"存着走"（原来只有继续挑战 ⇒ 想退出只能先进下一局再暂停）
		var save_quit := Button.new()
		save_quit.text = "保存并退出"
		save_quit.custom_minimum_size = Vector2(260, 50)
		save_quit.add_theme_font_size_override("font_size", 20)
		save_quit.pressed.connect(_on_ladder_save_quit)
		box.add_child(save_quit)
		return   # 天梯：结算面板不再有"返回"类按钮（退出走这里或暂停键）
	if ladder and not win:
		# 输了 = 本轮已经结束（存档在 `_ladder_on_match_result()` 里删掉了）⇒ 只剩"回主菜单"一条路；
		# 「保存并退出 / 放弃本次天梯」在**暂停界面**（对局中退出用那两个）。
		var back := Button.new()
		back.text = "返回主菜单"
		back.custom_minimum_size = Vector2(260, 50)
		back.add_theme_font_size_override("font_size", 20)
		back.pressed.connect(_on_back_to_menu)
		box.add_child(back)
		# 【2026-09-25 用户要求】原来这里还有一行小字「本轮已结束（最高连胜 N 场保留）」⇒ **整块删掉**
		#   （用户原话「最下面那行本轮已结束（...）也去掉」）。
		return

	var again := Button.new()
	again.text = "再来一局" if GameState.is_online else "再战一局"
	again.custom_minimum_size = Vector2(260, 52)
	again.add_theme_font_size_override("font_size", 20)
	again.pressed.connect(_on_restart.bind(true))   # 结束后再战一局：竞技场重新选人
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
		# 联机（含联机竞技场）：先通知对方"本端离开本局"，再断开并回联机大厅
		if NetBus.is_online:
			NetBus.send_all(JSON.stringify({ "type": "leave" }))
			await get_tree().create_timer(0.2, false).timeout   # 给对方一点时间收包
		GameState.reset_online()
		NetBus.stop()
		get_tree().change_scene_to_file("res://scenes/NetLobby.tscn")
		return
	GameState.arena_mode = false   # 返回选人界面：退出竞技场模式（再来一局时不再走竞技场）
	# 【天梯】回主菜单**不算放弃**（用户拍板）：存档留着，下次进天梯可以继续；
	#   只把"本局属于天梯"这个标记清掉，免得之后玩普通/竞技场被当成天梯局。
	GameState.ladder_mode = ""
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

# 【2026-09-23 新增·用户要求】顶部阵亡标志的**单个槽**（原来是 `src/DeathMark.gd`，按用户要求
#   改成 HUD 的嵌套类 —— 与 `FlameIcon` 同一写法：界面自己的小控件就写在这里，不另开文件）。
#
# 为什么不是一个拼字符串的 Label（原来是 `"我方 ☠☠☠"`）：
#   ① 用户要求"死亡时卡面飞过去 → **标志出现** → 标志震动摇晃几下" ⇒ 需要能定位到**具体哪一个**
#      要出现的标记（拿它的屏幕矩形当飞行终点）、并只晃它一个；
#   ② 用户要求"**无死亡和有死亡要一样大**" ⇒ 字符串里的 `○`（U+25CB）与 `☠`（U+2620）字形尺寸不同，
#      拼在一起会让整行宽度/圆心位置漂。现在每槽是**固定尺寸方框**、两种标记都**自绘/自算尺寸**
#      （空圈 = `RING_D` 的圆环；骷髅按槽内径缩放）⇒ 整行永不漂。
#      ⚠️ 尺寸口径后来按用户反馈改过两次：先"骷髅太小"（槽 26→34、占比 0.86→0.92），
#      再"圆圈缩小点"（空圈直径单独给 `RING_D = 22`）⇒ **现在骷髅比空圈大**，不再是等大。
#   ③ 用户口径"**有骷髅头死亡标志就不要那个红圈了**" ⇒ 满槽只画骷髅（连淡圆底都不画）。
# `filled` 由 HUD 控制（延迟揭示：卡片落地后才置 true）。尺寸微调改下面 const。
class DeathMark extends Control:
	# 【2026-09-23 用户反馈三连】**①「骷髅头太小了」⇒ 槽 26 → 34、占比 0.86 → 0.92**（骷髅宽 18.9 → 27.6px）；
	#   **②「圆圈缩小点」⇒ 空圈直径单独给 `RING_D`**（不再和骷髅共用一个内径）；
	#   **③「单独把骷髅头放大点」⇒ 只抬 `SKULL_FILL` 0.92 → 1.06**（骷髅宽 27.6 → **31.8px**，空圈仍是 22px）。
	#   ⇒ 三个旋钮各管一件事：**骷髅大小动 `SKULL_FILL`（本行）**，槽位方框动 `SLOT_D`，空圈动 `RING_D`。
	#   `SKULL_FILL > 1` = 骷髅比槽内径还宽（还没到方框宽度 34 就放得下，不裁切）。
	const SLOT_D := 34.0        ## 每槽边长（像素）：槽位方框（也决定骷髅能长多大）
	const RING_D := 22.0        ## 空圈**直径**（独立于骷髅；22 = 放大之前那个圈的尺寸）
	const RING_PAD := 2.0       ## 骷髅缩放用的基准留白（骷髅内径 = SLOT_D − 2×RING_PAD = 30）
	const RING_W := 2.0         ## 空圈线宽
	const SKULL_FILL := 1.06    ## 骷髅宽度 ÷ 骷髅内径（0.92 = 比内径小一圈；1.06 = 比内径还宽一点）
	const SHAKE_PX := 3.0       ## 摇晃幅度（像素）
	const SHAKE_TIMES := 4      ## 摇晃几下（左右各算一下）

	var filled := false          ## false = 空心圆（尚未阵亡）；true = 骷髅（已阵亡）
	var mark_color := Color(0.5, 0.85, 1.0)   ## 我方=蓝、敌方=红（由 HUD 按阵营给）

	func _init(c: Color = Color(0.5, 0.85, 1.0)) -> void:
		mark_color = c
		custom_minimum_size = Vector2(SLOT_D, SLOT_D)
		size = Vector2(SLOT_D, SLOT_D)
		mouse_filter = Control.MOUSE_FILTER_IGNORE   # 纯显示，不拦鼠标（不挡棋盘点击）
		pivot_offset = Vector2(SLOT_D * 0.5, SLOT_D * 0.5)   # 缩放/摇晃绕中心

	func set_filled(v: bool) -> void:
		if filled == v:
			return
		filled = v
		queue_redraw()

	## HUD 在"卡片落地"那一刻调用：标志先出现（弹出）再摇晃几下。
	func pop_and_shake() -> void:
		if not is_inside_tree():
			return
		pivot_offset = size * 0.5
		var base := position
		scale = Vector2(0.35, 0.35)
		rotation = 0.0
		var t := create_tween()
		t.set_parallel(false)
		# ① 弹出：0.35 → 1.26 → 1.0（BACK 缓动，像"啪"地盖章）
		t.tween_property(self, "scale", Vector2(1.26, 1.26), 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		t.tween_property(self, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_SINE)
		# ② 摇晃：左右各几下 + 轻微旋转（"震动摇晃几下"）
		for i in SHAKE_TIMES:
			var dx := SHAKE_PX if i % 2 == 0 else -SHAKE_PX
			var rot := 0.16 if i % 2 == 0 else -0.16
			t.tween_property(self, "position", base + Vector2(dx, 0.0), 0.045)
			t.parallel().tween_property(self, "rotation", rot, 0.045)
		# ③ 回中
		t.tween_property(self, "position", base, 0.05)
		t.parallel().tween_property(self, "rotation", 0.0, 0.05)

	func _draw() -> void:
		var c := size * 0.5
		if not filled:
			# 空心圆：**自绘**（不用 `○` 字形），直径 = `RING_D`（用户要求"圆圈缩小点" ⇒ 单独给定，
			#   不再和骷髅共用一个内径：现在是"骷髅大、空圈小"）。
			draw_arc(c, maxf(RING_D * 0.5, 2.0), 0.0, TAU, 48, mark_color, RING_W, true)
			return
		# 已阵亡：**只画骷髅，不再画那个圈**（用户口径「有骷髅头死亡标志就不要那个红圈了」）
		#   —— 骷髅按"槽内径"缩放（比空圈大），这是用户"骷髅太小 → 调大、圆圈再缩小"两条口径的最终结果。
		var r := maxf(minf(size.x, size.y) * 0.5 - RING_PAD, 2.0)
		var font := get_theme_font("font")
		if font == null:
			return                                  # 无字体（headless 等）：什么都不画，不影响逻辑
		var fs := int(maxf(size.y * 0.92, 8.0))
		var gw := font.get_string_size("☠", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var gh := font.get_height(fs)
		if gw <= 0.0 or gh <= 0.0:
			return
		var k := (r * 2.0 * SKULL_FILL) / gw        # 横向缩放：骷髅宽度 = 骷髅内径 × SKULL_FILL（>1 就是比内径还宽）
		draw_set_transform(c, 0.0, Vector2(k, k))
		draw_string(font, Vector2(-gw * 0.5, gh * 0.34), "☠", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, mark_color)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# 【2026-09-23 新增·用户要求】英雄阵亡演出（一次性节点，演完自毁；同样按用户要求写成 HUD 的嵌套类）：
#   ① **卡面破碎升天**：原地炸成一堆六边形碎片，碎片向上飘散、旋转、淡出；
#   ② **一路引导到上方状态栏的阵亡标志位置**：一枚小卡片（六边形）先升空，再沿弧线飞向状态栏里
#      "下一个要出现的"阵亡标记槽（终点由 HUD 传进来的 Control 决定）；
#   ③ **落地回调**：卡片到达那一刻调用 `on_land` —— HUD 把那个槽置为"已阵亡"（标志出现）并播
#      弹出 + 摇晃。⇒ "标志出现"的时机 = 卡片落地，而不是死亡瞬间。
#
# ⚠️ **headless（RL 跑批 / 无窗口自检）直接跳过整段演出、立刻回调** ⇒ 跑批零额外开销、
#    行为与加这个特效之前**逐位一致**（HUD 那边也会立刻落格，不做延迟揭示）。
# ⚠️ 召唤物（骷髅兵等）不占阵亡标志位：HUD 传 `target = null` ⇒ 只做破碎升天、不飞、不回调。
# 视觉参数微调改下面 const。
class DeathFx extends Control:
	const SHARD_N := 12           ## 碎片个数
	const SHARD_LIFE := 0.5       ## 碎片寿命（秒）
	const SHARD_SPREAD := 46.0    ## 碎片横向散开距离
	const RISE_H := 62.0          ## "升天"高度（像素）
	const RISE_TIME := 0.34       ## 升空时间
	const FLY_TIME := 0.55        ## 从升空顶点飞到标记槽的时间
	const CARD_R := 13.0          ## 飞行卡片（六边形）半径
	const CARD_END_SCALE := 0.5   ## 飞到终点时卡片缩到多小（像被标记"吸进去"）
	const ARC_H := 46.0           ## 飞行弧线向上凸起的高度

	func play(start: Vector2, target: Control, color: Color, on_land: Callable) -> void:
		# 无窗口/跑批：不做演出，直接"落格"（HUD 的延迟揭示因此退化成立即显示 = 老行为）
		if DisplayServer.get_name() == "headless":
			if on_land.is_valid():
				on_land.call()
			queue_free()
			return
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_shards(start, color)
		var token := _make_card(start, color)
		var apex := start + Vector2(0.0, -RISE_H)
		var t := create_tween()
		# ① 升空（碎片同时在飘）
		t.tween_property(token, "position", apex, RISE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.parallel().tween_property(token, "rotation", 0.55, RISE_TIME)
		t.parallel().tween_property(token, "scale", Vector2.ONE, RISE_TIME).from(Vector2(0.6, 0.6))
		if target == null or not is_instance_valid(target):
			# 召唤物：只破碎升天，不飞、不占标志位
			t.tween_interval(0.12)
			t.tween_callback(queue_free)
			return
		# ② 弧线飞向标记槽
		var dest: Vector2 = target.get_global_transform_with_canvas().origin + target.size * 0.5
		var mid: Vector2 = apex.lerp(dest, 0.5) + Vector2(0.0, -ARC_H)
		t.tween_callback(func(): _burst(dest, color))
		t.tween_method(func(k: float): token.position = _bezier(apex, mid, dest, k), 0.0, 1.0, FLY_TIME) \
			.set_trans(Tween.TRANS_SINE)
		t.parallel().tween_property(token, "scale", Vector2(CARD_END_SCALE, CARD_END_SCALE), FLY_TIME)
		t.parallel().tween_property(token, "rotation", 2.2, FLY_TIME)
		# ③ 落地：标志出现 + 摇晃（交给 HUD），卡片与特效节点收尾
		t.tween_callback(func():
			if on_land.is_valid():
				on_land.call())
		t.tween_interval(0.05)
		t.tween_callback(queue_free)

	# ---- 碎片：把"卡面"炸成一堆小六边形，向上飘散 ----
	func _make_shards(start: Vector2, color: Color) -> void:
		for i in SHARD_N:
			var sh := Polygon2D.new()
			var r := randf_range(3.0, 6.5)
			var pts := PackedVector2Array()
			for k in 6:
				var a := TAU * float(k) / 6.0 + randf() * 0.25
				pts.append(Vector2(cos(a), sin(a)) * r)
			sh.polygon = pts
			var c := color
			sh.color = Color(minf(c.r * randf_range(0.9, 1.35), 1.0), minf(c.g * randf_range(0.9, 1.35), 1.0),
				minf(c.b * randf_range(0.9, 1.35), 1.0), 1.0)
			sh.position = start + Vector2(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
			sh.rotation = randf() * TAU
			add_child(sh)
			# 方向：主要向上（-90° 附近散开），带一点横向
			var ang := -PI * 0.5 + randf_range(-0.85, 0.85)
			var dist := SHARD_SPREAD * randf_range(0.6, 1.25)
			var to := sh.position + Vector2(cos(ang), sin(ang)) * dist + Vector2(0.0, -RISE_H * randf_range(0.4, 0.9))
			var st := create_tween()
			st.set_parallel(true)
			st.tween_property(sh, "position", to, SHARD_LIFE).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			st.tween_property(sh, "rotation", sh.rotation + randf_range(-2.4, 2.4), SHARD_LIFE)
			st.tween_property(sh, "modulate:a", 0.0, SHARD_LIFE).set_delay(SHARD_LIFE * 0.35)
			st.chain().tween_callback(sh.queue_free)

	# ---- 飞行卡片：小六边形（外圈暗、内圈亮，像一枚徽记）----
	func _make_card(start: Vector2, color: Color) -> Node2D:
		var host := Node2D.new()
		host.position = start
		host.scale = Vector2(0.6, 0.6)
		add_child(host)
		var outer := Polygon2D.new()
		outer.polygon = _hex_pts(CARD_R)
		outer.color = Color(color.r * 0.55, color.g * 0.55, color.b * 0.55, 0.95)
		host.add_child(outer)
		var inner := Polygon2D.new()
		inner.polygon = _hex_pts(CARD_R * 0.62)
		inner.color = color
		host.add_child(inner)
		return host

	func _hex_pts(r: float) -> PackedVector2Array:
		var pts := PackedVector2Array()
		for i in 6:
			var a := TAU * float(i) / 6.0 - PI * 0.5   # 尖顶朝上（与棋盘六边形同朝向）
			pts.append(Vector2(cos(a), sin(a)) * r)
		return pts

	# ---- 落地小爆点：6 颗火星向外一闪（让"标志出现"更有手感）----
	func _burst(at: Vector2, color: Color) -> void:
		for i in 6:
			var sp := Polygon2D.new()
			sp.polygon = PackedVector2Array([Vector2(-1.6, -1.6), Vector2(1.6, -1.6), Vector2(1.6, 1.6), Vector2(-1.6, 1.6)])
			sp.color = color
			sp.position = at
			add_child(sp)
			var ang := TAU * float(i) / 6.0 + randf() * 0.3
			var st := create_tween()
			st.set_parallel(true)
			st.tween_property(sp, "position", at + Vector2(cos(ang), sin(ang)) * 15.0, 0.22)
			st.tween_property(sp, "modulate:a", 0.0, 0.22)
			st.chain().tween_callback(sp.queue_free)

	func _bezier(a: Vector2, b: Vector2, c: Vector2, k: float) -> Vector2:
		var u := 1.0 - k
		return u * u * a + 2.0 * u * k * b + k * k * c

# 【2026-09-23 搬家·用户口径「这种小功能不要另起文件」】音量调节控件：原来是 `src/VolumeControl.gd`
#   （带 `class_name VolumeControl`），现在收进 HUD 当嵌套类。**两处宿主**都在用：
#     · 战斗界面：本文件 `_build()` 末尾 `var volume := VolumeControl.new()`（右下角，与左下角喊话按钮对称）
#     · 主菜单：`src/Menu.gd` 里写 `HUD.VolumeControl.new()`（外层类名.嵌套类名 —— 跨文件访问嵌套类就这么写）
#   功能一字未改：自绘喇叭图标（音量 0-3 道声波弧、静音画红斜杠），点击弹出音量滑条面板
#   （独立 `CanvasLayer(70)` 保证盖过宿主 UI，点面板外收起）；音量由 `AudioManager` 统一读写并持久化
#   （`user://audio.cfg`），本控件只是它的界面。
class VolumeControl extends Control:
	const BTN_W := 76.0
	const BTN_H := 40.0
	const PANEL_W := 250.0
	const LAYER := 70

	var _layer: CanvasLayer = null
	var _panel: PanelContainer = null
	var _slider: HSlider = null
	var _val_label: Label = null
	var _vol := 1.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(BTN_W, BTN_H)
		size = Vector2(BTN_W, BTN_H)
		_vol = AudioManager.get_volume()
		queue_redraw()

	# 放视口右上角（宿主为满屏 Control/CanvasLayer 时坐标即视口坐标）
	func place_top_right(vsize: Vector2, margin_x := 8.0, margin_y := 7.0) -> void:
		position = Vector2(vsize.x - margin_x - BTN_W, margin_y)
		size = Vector2(BTN_W, BTN_H)

	# 放视口右下角（如战斗界面，与左下角喊话按钮对称）
	func place_bottom_right(vsize: Vector2, margin_x := 10.0, margin_b := 22.0) -> void:
		position = Vector2(vsize.x - margin_x - BTN_W, vsize.y - margin_b - BTN_H)
		size = Vector2(BTN_W, BTN_H)

	# ---- 自绘喇叭图标 ----
	func _draw() -> void:
		var muted := _vol <= 0.001
		var icon_c := Color(1.0, 0.9, 0.55, 0.95)
		if muted:
			icon_c = Color(1.0, 0.5, 0.45, 0.95)
		var midy := size.y / 2.0
		# 喇叭箱体 + 出声锥口
		var body := PackedVector2Array([
			Vector2(6, midy - 9), Vector2(17, midy - 9), Vector2(17, midy + 9), Vector2(6, midy + 9),
		])
		draw_colored_polygon(body, icon_c)
		var mouth := PackedVector2Array([
			Vector2(17, midy - 9), Vector2(26, midy - 14), Vector2(26, midy + 14), Vector2(17, midy + 9),
		])
		draw_colored_polygon(mouth, icon_c)
		if muted:
			# 静音：红色斜杠
			draw_line(Vector2(29, midy - 11), Vector2(55, midy + 11), Color(1.0, 0.4, 0.35, 0.95), 3.0, true)
			return
		# 按音量画 0-3 道声波弧
		var arcs := clampi(int(ceil(_vol * 3.0)), 0, 3)
		var from := -0.62
		var to := 0.62
		for i in arcs:
			var rad := 7.0 + float(i) * 5.0
			var col := Color(icon_c.r, icon_c.g, icon_c.b, maxf(0.95 - float(i) * 0.22, 0.35))
			draw_arc(Vector2(34.0, midy), rad, from, to, 14, col, 2.0, true)

	func _gui_input(ev: InputEvent) -> void:
		# 与全项目一致：触摸由 Godot 转成鼠标左键事件（安卓/iOS 默认开启），只处理鼠标事件避免双触发
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_toggle()
		accept_event()

	func _toggle() -> void:
		if _layer != null and is_instance_valid(_layer):
			_close_panel()
		else:
			_open_panel()

	# ---- 弹层（独立 CanvasLayer，全屏遮罩点外面即收起）----
	func _open_panel() -> void:
		if _layer != null and is_instance_valid(_layer):
			return
		var layer := CanvasLayer.new()
		layer.layer = LAYER
		add_child(layer)
		_layer = layer
		var overlay := Control.new()
		overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		overlay.gui_input.connect(_on_overlay_input)
		layer.add_child(overlay)
		# 半透明压暗背景（只轻微压暗，聚焦滑条）
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.22)
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.add_child(dim)
		# 面板：右上角喇叭按钮下方
		var panel := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.08, 0.1, 0.16, 0.95)
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		sb.set_border_width_all(1)
		sb.border_color = Color(1.0, 0.85, 0.5, 0.8)
		sb.content_margin_left = 14.0
		sb.content_margin_right = 14.0
		sb.content_margin_top = 12.0
		sb.content_margin_bottom = 12.0
		panel.add_theme_stylebox_override("panel", sb)
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		overlay.add_child(panel)
		_panel = panel
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 10)
		panel.add_child(v)
		var title := Label.new()
		title.text = "音效音量"
		title.add_theme_font_size_override("font_size", 17)
		title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(title)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		v.add_child(row)
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 100.0
		slider.step = 1.0
		slider.custom_minimum_size = Vector2(150, 40)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value = clampf(roundf(_vol * 100.0), 0.0, 100.0)
		slider.value_changed.connect(_on_volume_changed)
		# 松手后播一声"选择"音效，让玩家听到调节效果
		slider.drag_ended.connect(func(_changed: bool): AudioManager.play("select"))
		row.add_child(slider)
		_slider = slider
		var val := Label.new()
		val.text = _pct_text(int(slider.value))
		val.add_theme_font_size_override("font_size", 18)
		val.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val.custom_minimum_size = Vector2(52, 40)
		val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(val)
		_val_label = val
		var hint := Label.new()
		hint.text = "0 为静音 · 点喇叭/面板外收起"
		hint.add_theme_font_size_override("font_size", 12)
		hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(hint)
		# 定位：与喇叭按钮同侧对齐；按钮贴近上/下边缘时弹层自动改向另一侧，避免出屏
		panel.reset_size()
		var pw: float = maxf(panel.get_combined_minimum_size().x, PANEL_W)
		panel.custom_minimum_size = Vector2(pw, 0)
		panel.size = Vector2(pw, panel.get_combined_minimum_size().y)
		var gp := get_global_position()
		var gv := get_viewport().get_visible_rect().size
		var px := gp.x + BTN_W - pw
		px = clampf(px, 6.0, maxf(6.0, gv.x - pw - 6.0))
		var ph: float = panel.size.y
		var py := gp.y + BTN_H + 6.0
		if py + ph > gv.y - 6.0:
			py = maxf(6.0, gp.y - ph - 6.0)   # 贴底时向上弹
		panel.position = Vector2(px, py)

	func _pct_text(p: int) -> String:
		if p <= 0:
			return "静音"
		return "%d%%" % p

	func _on_volume_changed(v: float) -> void:
		var vol := clampf(v / 100.0, 0.0, 1.0)
		AudioManager.set_volume(vol)
		_vol = vol
		if _val_label != null and is_instance_valid(_val_label):
			_val_label.text = _pct_text(int(roundf(v)))
		queue_redraw()

	func _on_overlay_input(ev: InputEvent) -> void:
		var mb := ev as InputEventMouseButton
		if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_close_panel()
		accept_event()

	func _close_panel() -> void:
		if _layer != null and is_instance_valid(_layer):
			_layer.queue_free()
		_layer = null
		_panel = null
		_slider = null
		_val_label = null
		queue_redraw()
